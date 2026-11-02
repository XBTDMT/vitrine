import Foundation

/// What an iCalendar file (`.ics`, RFC 5545) holds (N-4): the calendar's name and, for an invitation, its method;
/// each event with when, where, who organised it, who is invited and how they answered, whether and how it repeats,
/// and its reminders; and each to-do. These are the file owner's own invitations, so values are kept as written.
/// roadmap: S-23
public struct CalendarSummary: Sendable, Equatable {
    /// A start, end or due time as the file writes it, and the moment it means when that is known. roadmap: S-23
    public struct When: Sendable, Equatable {
        /// The wall-clock fields as written (year…day for a date, year…second for a date-time).
        public var components: DateComponents
        /// A date with no time of day (`VALUE=DATE`): an all-day event's day.
        public var isAllDay: Bool
        /// `Z` (UTC) times.
        public var isUTC: Bool
        /// The `TZID` parameter as written.
        public var timeZoneID: String?
        /// The time zone the time was read in, when it is UTC or a zone this Mac knows (IANA names, common Windows
        /// names, or the fixed offset of the file's own VTIMEZONE).
        public var timeZone: TimeZone?
        /// The moment, when the zone is known (UTC, a known TZID); all-day dates and floating times are read in
        /// UTC so they sort, and `isFloating` says the clock time is what matters.
        public var date: Date?
        /// No zone at all: the same clock time wherever the reader is (and every all-day date).
        public var isFloating: Bool
    }

    /// A person in an invitation. roadmap: S-23
    public struct Person: Sendable, Equatable {
        public var name: String?
        /// The address from a `mailto:` value (lowercase scheme removed); other URIs as written.
        public var email: String?
    }

    /// An invited person and their answer. roadmap: S-23
    public struct Attendee: Sendable, Equatable {
        public var person: Person
        /// PARTSTAT uppercased (`ACCEPTED`, `DECLINED`, `TENTATIVE`, `NEEDS-ACTION`, `DELEGATED`); `NEEDS-ACTION`
        /// when absent, as RFC 5545 says.
        public var status: String
        /// ROLE uppercased (`REQ-PARTICIPANT`, `OPT-PARTICIPANT`, `CHAIR`, `NON-PARTICIPANT`), nil when absent.
        public var role: String?
        public var rsvpRequested: Bool
    }

    /// How the invited people answered. roadmap: S-23
    public struct Answers: Sendable, Equatable {
        public var accepted = 0, declined = 0, tentative = 0, needsAction = 0, delegated = 0, other = 0

        public init() {}
    }

    /// A reminder on an event or to-do. roadmap: S-23
    public struct Alarm: Sendable, Equatable {
        /// ACTION uppercased (`DISPLAY`, `AUDIO`, `EMAIL`, `PROCEDURE`).
        public var action: String
        /// The trigger in plain words: "15 minutes before the start", "at 2026-11-03 09:00 UTC".
        public var trigger: String
        /// The trigger as a signed offset in seconds from the start (or end), when it is relative.
        public var offset: TimeInterval?
    }

    /// One VEVENT. roadmap: S-23
    public struct Event: Sendable, Equatable {
        public var uid: String?
        public var summary: String?
        /// At most 4,000 characters.
        public var description: String?
        public var location: String?
        public var url: String?
        public var start: When?
        public var end: When?
        /// DURATION in seconds, when the event states one instead of an end.
        public var duration: TimeInterval?
        public var isAllDay: Bool
        public var organizer: Person?
        /// At most `CalendarSummary.maxAttendees`.
        public var attendees: [Attendee]
        public var attendeeCount: Int
        public var answers: Answers
        /// STATUS uppercased (`CONFIRMED`, `TENTATIVE`, `CANCELLED`).
        public var status: String?
        /// The repeat rule in plain words ("Every 2 weeks on Monday and Wednesday, 10 times").
        public var recurrence: String?
        /// The RRULE as written.
        public var recurrenceRule: String?
        /// Dates excluded from the repeats.
        public var exceptionCount: Int
        public var alarms: [Alarm]
        public var categories: [String]
        public var sequence: Int?
    }

    /// One VTODO. roadmap: S-23
    public struct Todo: Sendable, Equatable {
        public var summary: String?
        public var due: When?
        public var start: When?
        /// STATUS uppercased (`NEEDS-ACTION`, `IN-PROCESS`, `COMPLETED`, `CANCELLED`).
        public var status: String?
        /// 1 (highest) … 9; 0 or nil means undefined.
        public var priority: Int?
        public var percentComplete: Int?
        public var isCompleted: Bool
        public var alarms: [Alarm]
    }

    public static let maxEvents = 5_000
    public static let maxTodos = 5_000
    public static let maxAttendees = 500

    /// X-WR-CALNAME or NAME.
    public var name: String?
    public var productID: String?
    /// METHOD uppercased: `REQUEST` (an invitation), `REPLY`, `CANCEL`, `PUBLISH`…
    public var method: String?
    /// TZIDs of the file's VTIMEZONE blocks.
    public var timeZones: [String]
    public var events: [Event]
    public var eventCount: Int
    public var todos: [Todo]
    public var todoCount: Int
    public var warnings: [EverydayWarning]
    public var truncated: Bool

    public var headline: String {
        if eventCount == 1, let summary = events.first?.summary { return summary }
        if let name { return name }
        if eventCount == 0, todoCount == 1, let summary = todos.first?.summary { return summary }
        return eventCount > 0
            ? String(localized: "\(eventCount) events", bundle: .module, comment: "Headline of a calendar card; the argument is a count of events.")
            : String(localized: "Calendar", bundle: .module, comment: "Headline of a calendar card with no events and no name.")
    }

    public var facts: [EverydayFact] {
        var facts: [EverydayFact] = []
        if let name {
            facts.append(EverydayFact(String(localized: "Calendar", bundle: .module, comment: "Fact label on a calendar card: the calendar's name."), name))
        }
        if let method {
            facts.append(EverydayFact(String(localized: "Kind", bundle: .module, comment: "Fact label on a calendar card: invitation, reply, cancellation…"),
                                      CalendarSummary.methodWords(method)))
        }
        facts.append(EverydayFact(String(localized: "Events", bundle: .module, comment: "Fact label on a calendar card: number of events."), "\(eventCount)"))
        if todoCount > 0 {
            facts.append(EverydayFact(String(localized: "To-dos", bundle: .module, comment: "Fact label on a calendar card: number of to-dos."), "\(todoCount)"))
        }
        if eventCount == 1, let event = events.first {
            if let location = event.location {
                facts.append(EverydayFact(String(localized: "Where", bundle: .module, comment: "Fact label on a calendar card: the event's location."), location))
            }
            if let organizer = event.organizer {
                facts.append(EverydayFact(String(localized: "Organizer", bundle: .module, comment: "Fact label on a calendar card: who organised the event."),
                                          organizer.name ?? organizer.email ?? ""))
            }
            if event.attendeeCount > 0 {
                facts.append(EverydayFact(String(localized: "Invited", bundle: .module, comment: "Fact label on a calendar card: number of people invited."),
                                          "\(event.attendeeCount)"))
            }
            if let recurrence = event.recurrence {
                facts.append(EverydayFact(String(localized: "Repeats", bundle: .module, comment: "Fact label on a calendar card: the repeat rule in words."), recurrence))
            }
        }
        if !timeZones.isEmpty {
            facts.append(EverydayFact(String(localized: "Time zones", bundle: .module, comment: "Fact label on a calendar card: time zones the file defines."),
                                      timeZones.joined(separator: ", ")))
        }
        return facts
    }

    static func methodWords(_ method: String) -> String {
        switch method {
        case "REQUEST": String(localized: "Invitation", bundle: .module, comment: "Kind of calendar file (iCalendar METHOD REQUEST): an invitation to an event.")
        case "REPLY": String(localized: "Reply to an invitation", bundle: .module, comment: "Kind of calendar file (iCalendar METHOD REPLY).")
        case "CANCEL": String(localized: "Cancellation", bundle: .module, comment: "Kind of calendar file (iCalendar METHOD CANCEL): an event cancelled by its organiser.")
        case "PUBLISH": String(localized: "Published calendar", bundle: .module, comment: "Kind of calendar file (iCalendar METHOD PUBLISH): a calendar shared to read.")
        case "COUNTER": String(localized: "Counter-proposal", bundle: .module, comment: "Kind of calendar file (iCalendar METHOD COUNTER): an attendee proposes another time.")
        case "REFRESH": String(localized: "Refresh request", bundle: .module, comment: "Kind of calendar file (iCalendar METHOD REFRESH): an attendee asks for the latest version.")
        case "ADD": String(localized: "Added occurrences", bundle: .module, comment: "Kind of calendar file (iCalendar METHOD ADD): new dates added to a repeating event.")
        case "DECLINECOUNTER": String(localized: "Declined counter-proposal", bundle: .module, comment: "Kind of calendar file (iCalendar METHOD DECLINECOUNTER).")
        default: method
        }
    }
}

/// The iCalendar parser behind `CalendarSummary`.
enum EverydayCalendar {
    struct Component { var name: String; var lines: [EverydayContentLine] = []; var children: [Component] = [] }

    static func read(_ bytes: [UInt8]) -> CalendarSummary? {
        let (lines, linesTruncated) = EverydayContentLines.unfold(EverydayText.decode(bytes))
        guard lines.contains(where: { $0.uppercased().hasPrefix("BEGIN:VCALENDAR") || $0.uppercased().hasPrefix("BEGIN:VEVENT") }) else {
            return nil
        }
        var summary = CalendarSummary(name: nil, productID: nil, method: nil, timeZones: [], events: [], eventCount: 0,
                                      todos: [], todoCount: 0, warnings: [], truncated: linesTruncated)

        // Components are nested (VCALENDAR > VEVENT > VALARM, VTIMEZONE > STANDARD); gather each into a node.
        var stack: [Component] = []
        var roots: [Component] = []
        var unterminated = false
        var malformed = 0
        for raw in lines {
            guard let line = EverydayContentLines.parse(raw) else { malformed += 1; continue }
            if line.name == "BEGIN" {
                if stack.count >= 16 { summary.truncated = true; continue }
                stack.append(Component(name: line.value.uppercased().trimmingCharacters(in: .whitespaces)))
            } else if line.name == "END" {
                let name = line.value.uppercased().trimmingCharacters(in: .whitespaces)
                guard let index = stack.lastIndex(where: { $0.name == name }) else { malformed += 1; continue }
                while stack.count > index + 1 {    // close anything left open inside it
                    let inner = stack.removeLast()
                    stack[stack.count - 1].children.append(inner)
                    unterminated = true
                }
                let done = stack.removeLast()
                if stack.isEmpty { roots.append(done) } else { stack[stack.count - 1].children.append(done) }
            } else if !stack.isEmpty, stack[stack.count - 1].lines.count < 10_000 {
                stack[stack.count - 1].lines.append(line)
            }
        }
        if !stack.isEmpty {
            unterminated = true
            while stack.count > 1 { let inner = stack.removeLast(); stack[stack.count - 1].children.append(inner) }
            roots.append(stack.removeLast())
        }

        let calendars = roots.filter { $0.name == "VCALENDAR" }
        let containers = calendars.isEmpty ? [Component(name: "VCALENDAR", children: roots)] : calendars
        // The file's own zones, as fixed offsets for TZIDs this Mac does not know.
        var zoneOffsets: [String: Int] = [:]
        for container in containers {
            for line in container.lines {
                switch line.name {
                case "X-WR-CALNAME", "NAME": if summary.name == nil, !line.text.isEmpty { summary.name = line.text }
                case "PRODID": summary.productID = line.text
                case "METHOD": summary.method = line.text.uppercased()
                default: break
                }
            }
            for zone in container.children where zone.name == "VTIMEZONE" {
                guard let id = zone.lines.first(where: { $0.name == "TZID" })?.text else { continue }
                if !summary.timeZones.contains(id), summary.timeZones.count < 100 { summary.timeZones.append(id) }
                let standard = zone.children.first { $0.name == "STANDARD" } ?? zone.children.first
                if let offset = standard?.lines.first(where: { $0.name == "TZOFFSETTO" }).flatMap({ utcOffset($0.text) }) {
                    zoneOffsets[id] = offset
                }
            }
        }
        var unknownZones: [String] = []
        func when(_ line: EverydayContentLine?) -> CalendarSummary.When? {
            guard let line else { return nil }
            let result = parseWhen(line.value, tzid: line.parameter("TZID"),
                                   dateOnly: line.parameter("VALUE")?.uppercased() == "DATE", zoneOffsets: zoneOffsets)
            if let result, let id = result.timeZoneID, result.timeZone == nil, !unknownZones.contains(id) {
                unknownZones.append(id)
            }
            return result
        }

        var dangerousAlarms = 0
        var badRanges = 0
        var missingStarts = 0
        for container in containers {
            for component in container.children {
                switch component.name {
                case "VEVENT":
                    summary.eventCount += 1
                    guard summary.events.count < CalendarSummary.maxEvents else { summary.truncated = true; continue }
                    var event = CalendarSummary.Event(isAllDay: false, attendees: [], attendeeCount: 0, answers: .init(),
                                                      exceptionCount: 0, alarms: [], categories: [])
                    for line in component.lines {
                        switch line.name {
                        case "UID": event.uid = line.text
                        case "SUMMARY": event.summary = nonEmpty(line.text)
                        case "DESCRIPTION": event.description = nonEmpty(line.text).map { EverydayText.cap($0, 4_000) }
                        case "LOCATION": event.location = nonEmpty(line.text)
                        case "URL": event.url = nonEmpty(line.text)
                        case "DTSTART": event.start = when(line)
                        case "DTEND": event.end = when(line)
                        case "DURATION": event.duration = parseDuration(line.text)
                        case "STATUS": event.status = line.text.uppercased()
                        case "SEQUENCE": event.sequence = Int(line.text.trimmingCharacters(in: .whitespaces))
                        case "RRULE":
                            event.recurrenceRule = line.value
                            event.recurrence = describeRule(line.value)
                        case "EXDATE": event.exceptionCount += line.value.split(separator: ",").count
                        case "CATEGORIES":
                            for category in line.components(",") where !category.isEmpty && event.categories.count < 50 {
                                event.categories.append(category)
                            }
                        case "ORGANIZER": event.organizer = person(line)
                        case "ATTENDEE":
                            event.attendeeCount += 1
                            let status = line.parameter("PARTSTAT")?.uppercased() ?? "NEEDS-ACTION"
                            switch status {
                            case "ACCEPTED": event.answers.accepted += 1
                            case "DECLINED": event.answers.declined += 1
                            case "TENTATIVE": event.answers.tentative += 1
                            case "NEEDS-ACTION": event.answers.needsAction += 1
                            case "DELEGATED": event.answers.delegated += 1
                            default: event.answers.other += 1
                            }
                            if event.attendees.count < CalendarSummary.maxAttendees {
                                event.attendees.append(.init(person: person(line), status: status,
                                                             role: line.parameter("ROLE")?.uppercased(),
                                                             rsvpRequested: line.parameter("RSVP")?.uppercased() == "TRUE"))
                            } else {
                                summary.truncated = true
                            }
                        default: break
                        }
                    }
                    event.isAllDay = event.start?.isAllDay ?? false
                    if event.start == nil { missingStarts += 1 }
                    if let s = event.start?.date, let e = event.end?.date, e < s { badRanges += 1 }
                    event.alarms = alarms(component.children, &dangerousAlarms)
                    summary.events.append(event)
                case "VTODO":
                    summary.todoCount += 1
                    guard summary.todos.count < CalendarSummary.maxTodos else { summary.truncated = true; continue }
                    var todo = CalendarSummary.Todo(isCompleted: false, alarms: [])
                    for line in component.lines {
                        switch line.name {
                        case "SUMMARY": todo.summary = nonEmpty(line.text)
                        case "DUE": todo.due = when(line)
                        case "DTSTART": todo.start = when(line)
                        case "STATUS": todo.status = line.text.uppercased()
                        case "PRIORITY": todo.priority = Int(line.text.trimmingCharacters(in: .whitespaces))
                        case "PERCENT-COMPLETE": todo.percentComplete = Int(line.text.trimmingCharacters(in: .whitespaces))
                        case "COMPLETED": todo.isCompleted = true
                        default: break
                        }
                    }
                    if todo.status == "COMPLETED" { todo.isCompleted = true }
                    todo.alarms = alarms(component.children, &dangerousAlarms)
                    summary.todos.append(todo)
                default: break
                }
            }
        }

        if dangerousAlarms > 0 {
            summary.warnings.append(EverydayWarning(.danger, code: "calendar.procedureAlarm",
                reason: String(localized: "A reminder asks the calendar app to run a program (an obsolete PROCEDURE alarm).", bundle: .module,
                               comment: "Warning on a calendar card. PROCEDURE is an iCalendar keyword and stays as it is.")))
        }
        if !unknownZones.isEmpty {
            let zones = unknownZones.prefix(3).joined(separator: ", ")
            summary.warnings.append(EverydayWarning(.caution, code: "calendar.unknownTimeZone",
                reason: String(localized: "Times in \(zones) are shown as written: the time zone is not one this Mac knows.", bundle: .module,
                               comment: "Warning on a calendar card; the argument is one or more time zone names from the file.")))
        }
        if badRanges > 0 {
            summary.warnings.append(EverydayWarning(.caution, code: "calendar.endBeforeStart",
                reason: String(localized: "\(badRanges) events end before they start.", bundle: .module,
                               comment: "Warning on a calendar card; the argument is a count of events.")))
        }
        if missingStarts > 0 {
            summary.warnings.append(EverydayWarning(.caution, code: "calendar.missingStart",
                reason: String(localized: "\(missingStarts) events have no start time.", bundle: .module,
                               comment: "Warning on a calendar card; the argument is a count of events.")))
        }
        if unterminated || malformed > 0 {
            summary.warnings.append(EverydayWarning(.caution, code: "calendar.malformed",
                reason: String(localized: "Parts of the file are not well formed (unclosed blocks or unreadable lines); the rest was read.", bundle: .module,
                               comment: "Warning on a calendar card.")))
        }
        return summary
    }

    static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func person(_ line: EverydayContentLine) -> CalendarSummary.Person {
        var address = line.text.trimmingCharacters(in: .whitespaces)
        if address.lowercased().hasPrefix("mailto:") { address = String(address.dropFirst(7)) }
        let name = line.parameter("CN").flatMap(nonEmpty)
        return .init(name: name, email: address.isEmpty ? nil : address)
    }

    static func alarms(_ children: [Component], _ dangerous: inout Int) -> [CalendarSummary.Alarm] {
        var result: [CalendarSummary.Alarm] = []
        for alarm in children where alarm.name == "VALARM" && result.count < 20 {
            let action = alarm.lines.first { $0.name == "ACTION" }?.text.uppercased() ?? "DISPLAY"
            if action == "PROCEDURE" { dangerous += 1 }
            guard let trigger = alarm.lines.first(where: { $0.name == "TRIGGER" }) else {
                result.append(.init(action: action,
                                    trigger: String(localized: "with no trigger", bundle: .module,
                                                    comment: "A calendar reminder that does not say when it goes off."),
                                    offset: nil))
                continue
            }
            let relatedToEnd = trigger.parameter("RELATED")?.uppercased() == "END"
            if trigger.parameter("VALUE")?.uppercased() == "DATE-TIME" || !trigger.text.contains("P"),
               let at = parseWhen(trigger.text, tzid: nil, dateOnly: false, zoneOffsets: [:]) {
                let c = at.components
                let stamp = String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
                    + (at.isUTC ? " UTC" : "")
                let words = String(localized: "at \(stamp)", bundle: .module,
                                   comment: "When a calendar reminder goes off; the argument is a date and time like 2026-11-03 09:00 UTC.")
                result.append(.init(action: action, trigger: words, offset: nil))
            } else if let offset = parseDuration(trigger.text), let words = offsetWords(offset, relatedToEnd: relatedToEnd) {
                result.append(.init(action: action, trigger: words, offset: offset))
            } else {
                result.append(.init(action: action, trigger: trigger.text, offset: nil))
            }
        }
        return result
    }

    /// -900 → "15 minutes before the start"; 0 → "at the start"; nil when the offset is not a number or too large
    /// for whole seconds (the caller then shows the trigger as written).
    static func offsetWords(_ offset: TimeInterval, relatedToEnd: Bool) -> String? {
        guard let seconds = FormatMath.int(abs(offset)) else { return nil }
        guard seconds > 0 else {
            return relatedToEnd
                ? String(localized: "at the end", bundle: .module, comment: "A calendar reminder that goes off when the event ends.")
                : String(localized: "at the start", bundle: .module, comment: "A calendar reminder that goes off when the event starts.")
        }
        let amount: String
        if seconds % 604_800 == 0 {
            let n = seconds / 604_800
            amount = String(localized: "\(n) weeks", bundle: .module, comment: "A length of time in a calendar reminder; the argument is a count.")
        } else if seconds % 86_400 == 0 {
            let n = seconds / 86_400
            amount = String(localized: "\(n) days", bundle: .module, comment: "A length of time in a calendar reminder; the argument is a count.")
        } else if seconds % 3_600 == 0 {
            let n = seconds / 3_600
            amount = String(localized: "\(n) hours", bundle: .module, comment: "A length of time in a calendar reminder; the argument is a count.")
        } else if seconds % 60 == 0 {
            let n = seconds / 60
            amount = String(localized: "\(n) minutes", bundle: .module, comment: "A length of time in a calendar reminder; the argument is a count.")
        } else {
            amount = String(localized: "\(seconds) seconds", bundle: .module, comment: "A length of time in a calendar reminder; the argument is a count.")
        }
        switch (offset < 0, relatedToEnd) {
        case (true, false):
            return String(localized: "\(amount) before the start", bundle: .module,
                          comment: "When a calendar reminder goes off; the argument is a length of time like 15 minutes.")
        case (false, false):
            return String(localized: "\(amount) after the start", bundle: .module,
                          comment: "When a calendar reminder goes off; the argument is a length of time like 15 minutes.")
        case (true, true):
            return String(localized: "\(amount) before the end", bundle: .module,
                          comment: "When a calendar reminder goes off; the argument is a length of time like 15 minutes.")
        case (false, true):
            return String(localized: "\(amount) after the end", bundle: .module,
                          comment: "When a calendar reminder goes off; the argument is a length of time like 15 minutes.")
        }
    }

    // MARK: Dates and times

    /// `20261103`, `20261103T090000`, `20261103T090000Z` with an optional TZID.
    static func parseWhen(_ raw: String, tzid: String?, dateOnly: Bool, zoneOffsets: [String: Int]) -> CalendarSummary.When? {
        let value = raw.trimmingCharacters(in: .whitespaces).split(separator: ",").first.map(String.init) ?? ""
        let digits = Array(value.utf8)
        func number(_ from: Int, _ count: Int) -> Int? {
            guard from + count <= digits.count else { return nil }
            var n = 0
            for b in digits[from..<(from + count)] {
                guard (0x30...0x39).contains(b) else { return nil }
                n = n * 10 + Int(b - 0x30)
            }
            return n
        }
        guard let year = number(0, 4), let month = number(4, 2), let day = number(6, 2),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents(year: year, month: month, day: day)
        let hasTime = digits.count >= 15 && digits[8] == UInt8(ascii: "T")
        let allDay = dateOnly || !hasTime
        var isUTC = false
        if hasTime {
            guard let h = number(9, 2), let m = number(11, 2), let s = number(13, 2), h < 25, m < 60, s < 61 else { return nil }
            components.hour = h
            components.minute = m
            components.second = s
            isUTC = digits.count >= 16 && digits[15] == UInt8(ascii: "Z")
        }
        var zone: TimeZone?
        if isUTC {
            zone = TimeZone(identifier: "UTC")
        } else if let tzid, !allDay {
            zone = resolveZone(tzid, zoneOffsets: zoneOffsets)
        }
        let floating = allDay || (!isUTC && tzid == nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? TimeZone(identifier: "UTC")!
        let date = (zone != nil || floating) ? calendar.date(from: components) : nil
        return .init(components: components, isAllDay: allDay, isUTC: isUTC, timeZoneID: tzid, timeZone: zone,
                     date: date, isFloating: floating)
    }

    /// Common Windows zone names Outlook writes as TZIDs, mapped to IANA names.
    static let windowsZones: [String: String] = [
        "Pacific Standard Time": "America/Los_Angeles", "Mountain Standard Time": "America/Denver",
        "Central Standard Time": "America/Chicago", "Eastern Standard Time": "America/New_York",
        "US Mountain Standard Time": "America/Phoenix", "Alaskan Standard Time": "America/Anchorage",
        "Hawaiian Standard Time": "Pacific/Honolulu", "Atlantic Standard Time": "America/Halifax",
        "GMT Standard Time": "Europe/London", "Greenwich Standard Time": "Atlantic/Reykjavik",
        "W. Europe Standard Time": "Europe/Berlin", "Romance Standard Time": "Europe/Paris",
        "Central Europe Standard Time": "Europe/Budapest", "Central European Standard Time": "Europe/Warsaw",
        "E. Europe Standard Time": "Europe/Chisinau", "FLE Standard Time": "Europe/Kiev", "GTB Standard Time": "Europe/Bucharest",
        "Russian Standard Time": "Europe/Moscow", "India Standard Time": "Asia/Kolkata", "China Standard Time": "Asia/Shanghai",
        "Tokyo Standard Time": "Asia/Tokyo", "Korea Standard Time": "Asia/Seoul", "Singapore Standard Time": "Asia/Singapore",
        "AUS Eastern Standard Time": "Australia/Sydney", "E. Australia Standard Time": "Australia/Brisbane",
        "New Zealand Standard Time": "Pacific/Auckland", "SA Pacific Standard Time": "America/Bogota",
        "E. South America Standard Time": "America/Sao_Paulo", "Arabian Standard Time": "Asia/Dubai",
        "Israel Standard Time": "Asia/Jerusalem", "South Africa Standard Time": "Africa/Johannesburg",
        "UTC": "UTC", "Coordinated Universal Time": "UTC",
    ]

    static func resolveZone(_ tzid: String, zoneOffsets: [String: Int]) -> TimeZone? {
        var id = tzid.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        if id.hasPrefix("/") { id.removeFirst() }       // "/Europe/Paris" (a globally unique id prefix)
        if let zone = TimeZone(identifier: id) { return zone }
        if let mapped = windowsZones[id], let zone = TimeZone(identifier: mapped) { return zone }
        // "/mozilla.org/20050126_1/Europe/Paris" and similar: try the last two path parts.
        let parts = id.split(separator: "/")
        if parts.count >= 2, let zone = TimeZone(identifier: parts.suffix(2).joined(separator: "/")) { return zone }
        if let offset = zoneOffsets[tzid] { return TimeZone(secondsFromGMT: offset) }
        return nil
    }

    /// `+0100`, `-0530`, `+013000` → seconds.
    static func utcOffset(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = text.dropFirst()
        guard digits.count == 4 || digits.count == 6, digits.allSatisfy(\.isNumber),
              let h = Int(digits.prefix(2)), let m = Int(digits.dropFirst(2).prefix(2)) else { return nil }
        let s = digits.count == 6 ? Int(digits.suffix(2)) ?? 0 : 0
        let total = h * 3600 + m * 60 + s
        return sign == "-" ? -total : total
    }

    /// `P1D`, `PT15M`, `-PT1H30M`, `P2W` → seconds (negative before).
    static func parseDuration(_ raw: String) -> TimeInterval? {
        var text = Substring(raw.trimmingCharacters(in: .whitespaces).uppercased())
        var sign: Double = 1
        if text.hasPrefix("-") { sign = -1; text = text.dropFirst() } else if text.hasPrefix("+") { text = text.dropFirst() }
        guard text.hasPrefix("P") else { return nil }
        text = text.dropFirst()
        var total: Double = 0
        var number = ""
        var sawUnit = false
        for c in text {
            if c.isNumber { number.append(c); continue }
            if c == "T" { continue }
            guard let n = Double(number) else { return nil }
            switch c {
            case "W": total += n * 604_800
            case "D": total += n * 86_400
            case "H": total += n * 3_600
            case "M": total += n * 60
            case "S": total += n
            default: return nil
            }
            number = ""
            sawUnit = true
        }
        guard sawUnit, number.isEmpty else { return nil }
        // A file can write any number of digits; a length past the span a calendar can hold (10,000 years) is not a
        // duration this reader can use, and is treated like unreadable text.
        guard total.isFinite, total <= maxDurationSeconds else { return nil }
        return sign * total
    }

    /// 10,000 years of 366 days, in seconds: past any date a calendar holds, and far inside what an Int holds.
    static let maxDurationSeconds: Double = 10_000 * 366 * 86_400

    // MARK: Recurrence rules in plain words

    static func dayName(_ code: String) -> String? {
        switch code {
        case "MO": String(localized: "Monday", bundle: .module, comment: "Day name in a repeat rule (Weekly on Monday).")
        case "TU": String(localized: "Tuesday", bundle: .module, comment: "Day name in a repeat rule (Weekly on Tuesday).")
        case "WE": String(localized: "Wednesday", bundle: .module, comment: "Day name in a repeat rule (Weekly on Wednesday).")
        case "TH": String(localized: "Thursday", bundle: .module, comment: "Day name in a repeat rule (Weekly on Thursday).")
        case "FR": String(localized: "Friday", bundle: .module, comment: "Day name in a repeat rule (Weekly on Friday).")
        case "SA": String(localized: "Saturday", bundle: .module, comment: "Day name in a repeat rule (Weekly on Saturday).")
        case "SU": String(localized: "Sunday", bundle: .module, comment: "Day name in a repeat rule (Weekly on Sunday).")
        default: nil
        }
    }

    static func monthName(_ month: Int) -> String? {
        switch month {
        case 1: String(localized: "January", bundle: .module, comment: "Month name in a repeat rule (Yearly in January).")
        case 2: String(localized: "February", bundle: .module, comment: "Month name in a repeat rule (Yearly in February).")
        case 3: String(localized: "March", bundle: .module, comment: "Month name in a repeat rule (Yearly in March).")
        case 4: String(localized: "April", bundle: .module, comment: "Month name in a repeat rule (Yearly in April).")
        case 5: String(localized: "May", bundle: .module, comment: "Month name in a repeat rule (Yearly in May).")
        case 6: String(localized: "June", bundle: .module, comment: "Month name in a repeat rule (Yearly in June).")
        case 7: String(localized: "July", bundle: .module, comment: "Month name in a repeat rule (Yearly in July).")
        case 8: String(localized: "August", bundle: .module, comment: "Month name in a repeat rule (Yearly in August).")
        case 9: String(localized: "September", bundle: .module, comment: "Month name in a repeat rule (Yearly in September).")
        case 10: String(localized: "October", bundle: .module, comment: "Month name in a repeat rule (Yearly in October).")
        case 11: String(localized: "November", bundle: .module, comment: "Month name in a repeat rule (Yearly in November).")
        case 12: String(localized: "December", bundle: .module, comment: "Month name in a repeat rule (Yearly in December).")
        default: nil
        }
    }

    /// "Weekly", "Every 2 weeks"…
    static func frequencyWords(_ freq: String, _ n: Int) -> String? {
        switch (freq, n == 1) {
        case ("SECONDLY", true): String(localized: "Every second", bundle: .module, comment: "Start of a repeat rule.")
        case ("SECONDLY", false): String(localized: "Every \(n) seconds", bundle: .module, comment: "Start of a repeat rule; the argument is the interval.")
        case ("MINUTELY", true): String(localized: "Every minute", bundle: .module, comment: "Start of a repeat rule.")
        case ("MINUTELY", false): String(localized: "Every \(n) minutes", bundle: .module, comment: "Start of a repeat rule; the argument is the interval.")
        case ("HOURLY", true): String(localized: "Hourly", bundle: .module, comment: "Start of a repeat rule: every hour.")
        case ("HOURLY", false): String(localized: "Every \(n) hours", bundle: .module, comment: "Start of a repeat rule; the argument is the interval.")
        case ("DAILY", true): String(localized: "Daily", bundle: .module, comment: "Start of a repeat rule: every day.")
        case ("DAILY", false): String(localized: "Every \(n) days", bundle: .module, comment: "Start of a repeat rule; the argument is the interval.")
        case ("WEEKLY", true): String(localized: "Weekly", bundle: .module, comment: "Start of a repeat rule: every week.")
        case ("WEEKLY", false): String(localized: "Every \(n) weeks", bundle: .module, comment: "Start of a repeat rule; the argument is the interval.")
        case ("MONTHLY", true): String(localized: "Monthly", bundle: .module, comment: "Start of a repeat rule: every month.")
        case ("MONTHLY", false): String(localized: "Every \(n) months", bundle: .module, comment: "Start of a repeat rule; the argument is the interval.")
        case ("YEARLY", true): String(localized: "Yearly", bundle: .module, comment: "Start of a repeat rule: every year.")
        case ("YEARLY", false): String(localized: "Every \(n) years", bundle: .module, comment: "Start of a repeat rule; the argument is the interval.")
        default: nil
        }
    }

    /// `FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=10` → "Every 2 weeks on Monday and Wednesday, 10 times".
    static func describeRule(_ rule: String) -> String? {
        var parts: [String: String] = [:]
        for piece in rule.split(separator: ";") {
            let kv = piece.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { parts[kv[0].trimmingCharacters(in: .whitespaces).uppercased()] = kv[1].trimmingCharacters(in: .whitespaces) }
        }
        guard let freq = parts["FREQ"]?.uppercased() else { return nil }
        let interval = max(1, Int(parts["INTERVAL"] ?? "1") ?? 1)
        guard var text = frequencyWords(freq, interval) else { return nil }
        var handled: Set<String> = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "WKST"]

        if let byMonth = parts["BYMONTH"] {
            let names = byMonth.split(separator: ",").compactMap { Int($0) }.compactMap(monthName)
            if !names.isEmpty {
                let months = list(names)
                text = String(localized: "\(text) in \(months)", bundle: .module,
                              comment: "Repeat rule part; the first argument is the rule so far (Yearly), the second one or more month names.")
                handled.insert("BYMONTH")
            }
        }
        if let byDay = parts["BYDAY"] {
            var plainDays: [String] = []
            var ordinalDays: [String] = []
            var codes = Set<String>()
            var ok = true
            for token in byDay.split(separator: ",") {
                let t = token.trimmingCharacters(in: .whitespaces).uppercased()
                guard let day = dayName(String(t.suffix(2))) else { ok = false; break }
                let ordinalText = String(t.dropLast(2))
                if ordinalText.isEmpty {
                    plainDays.append(day)
                    codes.insert(String(t.suffix(2)))
                } else if let n = Int(ordinalText), let phrase = ordinalDay(n, day) {
                    ordinalDays.append(phrase)
                } else {
                    ok = false
                    break
                }
            }
            if ok, !(plainDays.isEmpty && ordinalDays.isEmpty) {
                if ordinalDays.isEmpty, plainDays.count == 5, codes == ["MO", "TU", "WE", "TH", "FR"] {
                    text = String(localized: "\(text) on weekdays", bundle: .module,
                                  comment: "Repeat rule part; the argument is the rule so far (Weekly).")
                } else {
                    let days = list(ordinalDays + plainDays)
                    text = String(localized: "\(text) on \(days)", bundle: .module,
                                  comment: "Repeat rule part; the first argument is the rule so far (Weekly), the second one or more days (Monday and Wednesday, the first Monday, day 15).")
                }
                handled.insert("BYDAY")
            }
        }
        if let byMonthDay = parts["BYMONTHDAY"] {
            let days = byMonthDay.split(separator: ",").compactMap { Int($0) }
            if !days.isEmpty {
                let words = list(days.map { day in
                    day == -1
                        ? String(localized: "the last day", bundle: .module, comment: "Day of the month in a repeat rule (Monthly on the last day).")
                        : String(localized: "day \(day)", bundle: .module, comment: "Day of the month in a repeat rule (Monthly on day 15).")
                })
                text = String(localized: "\(text) on \(words)", bundle: .module,
                              comment: "Repeat rule part; the first argument is the rule so far (Weekly), the second one or more days (Monday and Wednesday, the first Monday, day 15).")
                handled.insert("BYMONTHDAY")
            }
        }
        if let count = parts["COUNT"].flatMap({ Int($0) }) {
            text = count == 1
                ? String(localized: "\(text), once", bundle: .module, comment: "Repeat rule ending; the argument is the rule so far.")
                : String(localized: "\(text), \(count) times", bundle: .module,
                         comment: "Repeat rule ending; the first argument is the rule so far, the second how many times it happens.")
        } else if let until = parts["UNTIL"], let when = parseWhen(until, tzid: nil, dateOnly: false, zoneOffsets: [:]) {
            let c = when.components
            let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            text = String(localized: "\(text), until \(day)", bundle: .module,
                          comment: "Repeat rule ending; the first argument is the rule so far, the second a date like 2026-12-31.")
        }
        if parts.keys.contains(where: { !handled.contains($0) }) {
            text = String(localized: "\(text) (with further rules)", bundle: .module,
                          comment: "Repeat rule ending when the rule has parts not put into words; the argument is the rule so far.")
        }
        return text
    }

    /// 1, "Monday" → "the first Monday"; -1 → "the last Monday".
    static func ordinalDay(_ n: Int, _ day: String) -> String? {
        switch n {
        case 1: String(localized: "the first \(day)", bundle: .module, comment: "In a repeat rule (Monthly on the first Monday); the argument is a day name.")
        case 2: String(localized: "the second \(day)", bundle: .module, comment: "In a repeat rule (Monthly on the second Monday); the argument is a day name.")
        case 3: String(localized: "the third \(day)", bundle: .module, comment: "In a repeat rule (Monthly on the third Monday); the argument is a day name.")
        case 4: String(localized: "the fourth \(day)", bundle: .module, comment: "In a repeat rule (Monthly on the fourth Monday); the argument is a day name.")
        case 5: String(localized: "the fifth \(day)", bundle: .module, comment: "In a repeat rule (Monthly on the fifth Monday); the argument is a day name.")
        case -1: String(localized: "the last \(day)", bundle: .module, comment: "In a repeat rule (Monthly on the last Friday); the argument is a day name.")
        case -2: String(localized: "the second to last \(day)", bundle: .module, comment: "In a repeat rule (Monthly on the second to last Friday); the argument is a day name.")
        default: nil
        }
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default:
            let head = items.dropLast().joined(separator: ", ")
            let last = items[items.count - 1]
            return String(localized: "\(head) and \(last)", bundle: .module,
                          comment: "Joins the last item of a list in a repeat rule (Monday, Tuesday and Friday); the first argument is the items before it, comma-separated.")
        }
    }
}
