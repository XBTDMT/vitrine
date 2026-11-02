import Foundation
import Testing
@testable import VitrineFormats

/// The everyday reader (S-23: N-3 subtitles, N-4 calendar and contacts, N-5 email, E-11 BibTeX and LaTeX). Every
/// fixture is invented here (people and addresses like ana@acme.example); the .msg is assembled with the CFB writer
/// at the bottom of this file. roadmap: S-23
@Suite struct EverydayTests {
    // MARK: Helpers

    func read(_ text: String, _ name: String) -> EverydayDocument? {
        EverydayReader.read(data: Data(text.utf8), fileName: name)
    }

    func subtitles(_ text: String, _ name: String) throws -> SubtitleSummary {
        guard case .subtitles(let s)? = read(text, name) else { throw Failure("not subtitles") }
        return s
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    func codes(_ warnings: [EverydayWarning]) -> Set<String> { Set(warnings.map(\.code)) }

    // MARK: Routing

    @Test func routesByExtensionThenContent() {
        #expect(EverydayReader.knownExtensions.contains("dfxp"))
        if case .subtitles? = read("WEBVTT\n\n00:01.000 --> 00:02.000\nHi\n", "clip.txt") {} else { Issue.record("vtt sniff") }
        if case .contacts? = read("BEGIN:VCARD\nVERSION:3.0\nFN:Ana Lima\nEND:VCARD\n", "card") {} else { Issue.record("vcard sniff") }
        if case .calendar? = read("BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:x\nEND:VEVENT\nEND:VCALENDAR\n", "invite.dat") {} else { Issue.record("ics sniff") }
        if case .subtitles? = read("1\n00:00:01,000 --> 00:00:02,000\nHi\n", "movie.sub") {} else { Issue.record("srt sniff") }
        #expect(read("just some words", "notes.txt") == nil)
        #expect(read("hello there", "invite.ics") == nil)
        #expect(read("hello there", "card.vcf") == nil)
        #expect(EverydayReader.read(data: Data(), fileName: "empty.msg") == nil)
        #expect(EverydayReader.read(data: Data(repeating: 0x41, count: 600), fileName: "x.msg") == nil)
    }

    // MARK: SubRip

    static let srt = """
    1
    00:00:01,000 --> 00:00:03,500
    <i>Hello</i>, Ana.

    2
    00:00:03,000 --> 00:00:05,000
    {\\an8}Overlapping line

    3
    00:01:30,000 --> 00:01:30,500
    This line is far too long to read in half a second

    garbage block without timing
    """

    @Test func srtCuesOverlapsGapsAndReadingSpeed() throws {
        let s = try subtitles(Self.srt, "movie.srt")
        #expect(s.format == .srt)
        #expect(s.cueCount == 3)
        #expect(s.cues[0].text == "Hello, Ana.")
        #expect(s.cues[0].identifier == "1")
        #expect(s.cues[1].text == "Overlapping line")
        #expect(s.cues[2].start == 90 && s.cues[2].end == 90.5)
        #expect(s.overlapCount == 1)
        #expect(s.longGaps.count == 1)
        #expect(s.longGaps.first?.afterCue == 2)
        #expect(s.totalDuration == 90.5)
        #expect(s.maxCharactersPerSecondCue == 3)
        #expect((s.maxCharactersPerSecond ?? 0) > 20)
        #expect(s.skippedCount == 1)
        #expect(codes(s.warnings) == ["subtitles.hardToRead", "subtitles.overlap", "subtitles.unreadable"])
        let hard = try #require(s.warnings.first { $0.code == "subtitles.hardToRead" })
        #expect(hard.level == .caution)
        #expect(hard.reason.contains("hard to read"))
        #expect(EverydayDocument.subtitles(s).headline == "SubRip subtitles")
        #expect(s.facts.contains(EverydayFact("Duration", "1:31")))
    }

    // MARK: WebVTT

    static let vtt = """
    WEBVTT - Demo
    Kind: captions
    Language: en-GB

    STYLE
    ::cue(.yellow) { color: yellow }

    NOTE This is a comment

    intro
    00:00.000 --> 00:02.000 line:0 align:start
    <v Ana>Hi <c.yellow>there</c></v>

    00:00:02.500 --> 00:00:04.000
    <lang fr>Bonjour</lang> &amp; adieu
    """

    @Test func webVTTHeaderNotesStylesVoicesAndSettings() throws {
        let s = try subtitles(Self.vtt, "clip.vtt")
        #expect(s.title == "Demo")
        #expect(s.languages == ["en-GB", "fr"])
        #expect(s.notes == ["This is a comment"])
        #expect(s.styles.map(\.name) == ["yellow"])
        #expect(s.cueCount == 2)
        let first = s.cues[0]
        #expect(first.identifier == "intro")
        #expect(first.text == "Hi there")
        #expect(first.speaker == "Ana")
        #expect(first.style == "yellow")
        #expect(first.settings == "line:0 align:start")
        #expect(s.cues[1].text == "Bonjour & adieu")
        #expect(s.warnings.isEmpty)
        #expect(s.metadata.contains(EverydayFact("Kind", "captions")))
    }

    @Test func webVTTWithoutHeaderWarns() throws {
        let s = try subtitles("00:01.000 --> 00:02.000\nHi\n", "bad.vtt")
        #expect(codes(s.warnings).contains("subtitles.missingHeader"))
        #expect(s.cueCount == 1)
    }

    // MARK: ASS / SSA

    static let ass = #"""
    [Script Info]
    Title: Demo Episode
    ScriptType: v4.00+

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour
    Style: Default,Arial,20,&H00FFFFFF
    Style: Sign,Helvetica,30,&H00FFFFFF

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:03.00,Default,Ana,0,0,0,,{\i1}Hello,{\i0} world\Nsecond line
    Dialogue: 0,0:00:02.00,0:00:04.00,Sign,,0,0,0,,{\pos(10,10)}EXIT
    Comment: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,ignored
    Dialogue: 0,bad,0:00:07.00,Default,,0,0,0,,broken
    """#

    @Test func assStylesEventsAndOverrideTags() throws {
        let s = try subtitles(Self.ass, "episode.ass")
        #expect(s.format == .ass)
        #expect(s.title == "Demo Episode")
        #expect(s.styles == [.init(name: "Default", font: "Arial", size: "20"), .init(name: "Sign", font: "Helvetica", size: "30")])
        #expect(s.cueCount == 2)
        #expect(s.cues[0].text == "Hello, world\nsecond line")
        #expect(s.cues[0].speaker == "Ana")
        #expect(s.cues[0].style == "Default")
        #expect(s.cues[1].text == "EXIT")
        #expect(s.cues[1].speaker == nil)
        // Signs over dialogue overlap by design in ASS: counted, not warned.
        #expect(s.overlapCount == 1)
        #expect(codes(s.warnings) == ["subtitles.unreadable"])
        let ssa = try subtitles(Self.ass.replacingOccurrences(of: "v4.00+", with: "v4.00"), "old.ssa")
        #expect(ssa.format == .ssa)
    }

    // MARK: TTML

    static let ttml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:tts="http://www.w3.org/ns/ttml#styling" xmlns:ttp="http://www.w3.org/ns/ttml#parameter" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="es" ttp:frameRate="25" ttp:tickRate="10000000">
     <head>
      <metadata><ttm:title>Demo TTML</ttm:title></metadata>
      <styling><style xml:id="s1" tts:fontFamily="Arial" tts:fontSize="80%"/></styling>
     </head>
     <body>
      <div begin="10s">
       <p xml:id="c1" begin="00:00:01.000" end="00:00:02.500" style="s1">Hola<br/>mundo</p>
       <p begin="00:00:03:12" dur="2s"><span ttm:agent="ana">Adiós</span></p>
       <p begin="50000000t" end="70000000t">Ticks</p>
       <p begin="1500ms" end="2m">Long</p>
      </div>
     </body>
    </tt>
    """

    @Test func ttmlTimeFormsInheritanceStylesAndAgents() throws {
        let s = try subtitles(Self.ttml, "captions.dfxp")
        #expect(s.format == .ttml)
        #expect(s.title == "Demo TTML")
        #expect(s.languages == ["es"])
        #expect(s.styles == [.init(name: "s1", font: "Arial", size: "80%")])
        #expect(s.cueCount == 4)
        let hola = try #require(s.cues.first { $0.text == "Hola\nmundo" })
        #expect(hola.start == 11 && hola.end == 12.5)
        #expect(hola.style == "s1")
        #expect(hola.identifier == "c1")
        let frames = try #require(s.cues.first { $0.text == "Adiós" })
        #expect(abs(frames.start - 13.48) < 0.0001)
        #expect(abs(frames.end - 15.48) < 0.0001)
        #expect(frames.speaker == "ana")
        let ticks = try #require(s.cues.first { $0.text == "Ticks" })
        #expect(ticks.start == 15 && ticks.end == 17)
        let long = try #require(s.cues.first { $0.text == "Long" })
        #expect(long.start == 11.5 && long.end == 130)
        #expect(s.totalDuration == 130)
    }

    @Test func ttmlRejectsOtherXMLAndSurvivesBrokenXML() throws {
        #expect(read("<?xml version=\"1.0\"?><feed><entry/></feed>", "x.ttml") == nil)
        let broken = try subtitles("<tt xml:lang=\"en\"><body><div><p begin=\"1s\" end=\"2s\">One</p><p begin=\"3s\"", "broken.ttml")
        #expect(codes(broken.warnings).contains("subtitles.xmlError"))
    }

    // MARK: LRC

    static let lrc = """
    [ar:Demo Artist]
    [ti:Demo Song]
    [la:pt]
    [offset:+500]
    [00:12.00]First line
    [00:17.20][00:40.00]Chorus <00:17.50>words
    [00:30.00]Third
    not a lyric line
    """

    @Test func lrcTagsOffsetsRepeatsAndWordStamps() throws {
        let s = try subtitles(Self.lrc, "song.lrc")
        #expect(s.title == "Demo Song")
        #expect(s.languages == ["pt"])
        #expect(s.metadata.contains(EverydayFact("ar", "Demo Artist")))
        #expect(s.cueCount == 4)
        #expect(s.cues.map(\.text) == ["First line", "Chorus words", "Third", "Chorus words"])
        #expect(s.cues.map(\.start) == [11.5, 16.7, 29.5, 39.5])
        #expect(s.cues[0].end == 16.7)
        #expect(s.cues[3].end == 39.5)
        #expect(s.maxCharactersPerSecond == nil)
        #expect(s.warnings.isEmpty)
        #expect(EverydayDocument.subtitles(s).facts.first { $0.label == "Lines" }?.value == "4")
    }

    @Test func subtitleClockAndEmptyFile() throws {
        #expect(SubtitleSummary.clock(3725) == "1:02:05")
        #expect(SubtitleSummary.clock(65) == "1:05")
        let empty = try subtitles("WEBVTT\n", "empty.vtt")
        #expect(codes(empty.warnings) == ["subtitles.empty"])
    }

    // MARK: Calendar

    static let ics = [
        "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Acme//Planner//EN", "METHOD:REQUEST", "X-WR-CALNAME:Team",
        "BEGIN:VTIMEZONE", "TZID:Acme Standard Time", "BEGIN:STANDARD", "DTSTART:19700101T000000", "TZOFFSETFROM:+0200",
        "TZOFFSETTO:+0100", "END:STANDARD", "END:VTIMEZONE",
        "BEGIN:VEVENT", "UID:evt-1@acme.example", "SUMMARY:Design review\\, round 2", "DESCRIPTION:Agenda:\\nOne\\n", " Two",
        "LOCATION:Room 4", "DTSTART;TZID=Europe/Lisbon:20261103T093000", "DTEND;TZID=Europe/Lisbon:20261103T103000",
        "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=10", "ORGANIZER;CN=Ana Lima:mailto:ana@acme.example",
        "ATTENDEE;CN=Bo Okafor;PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT;RSVP=TRUE:mailto:bo@acme.example",
        "ATTENDEE;CN=\"Chen, Cy\";PARTSTAT=DECLINED:mailto:cy@acme.example", "ATTENDEE:mailto:dee@acme.example",
        "BEGIN:VALARM", "ACTION:DISPLAY", "TRIGGER:-PT15M", "END:VALARM", "END:VEVENT",
        "BEGIN:VEVENT", "SUMMARY:Offsite", "DTSTART;VALUE=DATE:20261120", "DTEND;VALUE=DATE:20261122",
        "RRULE:FREQ=MONTHLY;BYDAY=-1FR;UNTIL=20271231T000000Z", "END:VEVENT",
        "BEGIN:VEVENT", "SUMMARY:Local zone", "DTSTART;TZID=Acme Standard Time:20261105T080000",
        "DTEND;TZID=Mars/Olympus:20261105T090000", "BEGIN:VALARM", "ACTION:PROCEDURE", "TRIGGER;RELATED=END:PT0S",
        "END:VALARM", "END:VEVENT",
        "BEGIN:VTODO", "SUMMARY:Send slides", "DUE:20261102T170000Z", "STATUS:COMPLETED", "PRIORITY:1", "END:VTODO",
        "END:VCALENDAR",
    ].joined(separator: "\r\n")

    @Test func calendarEventsAttendeesRulesZonesAndAlarms() throws {
        guard case .calendar(let c)? = read(Self.ics, "invite.ics") else { throw Failure("not a calendar") }
        #expect(c.name == "Team")
        #expect(c.method == "REQUEST")
        #expect(c.timeZones == ["Acme Standard Time"])
        #expect(c.eventCount == 3 && c.todoCount == 1)

        let review = c.events[0]
        #expect(review.summary == "Design review, round 2")
        #expect(review.description == "Agenda:\nOne\nTwo")
        #expect(review.location == "Room 4")
        #expect(review.start?.timeZone?.identifier == "Europe/Lisbon")
        #expect(review.start?.date == ISO8601DateFormatter().date(from: "2026-11-03T09:30:00Z"))
        #expect(review.start?.components.hour == 9)
        #expect(review.recurrence == "Every 2 weeks on Monday and Wednesday, 10 times")
        #expect(review.organizer == .init(name: "Ana Lima", email: "ana@acme.example"))
        #expect(review.attendeeCount == 3)
        #expect(review.attendees[1].person.name == "Chen, Cy")
        #expect(review.attendees[0].rsvpRequested)
        #expect(review.attendees[0].role == "REQ-PARTICIPANT")
        #expect(review.answers.accepted == 1 && review.answers.declined == 1 && review.answers.needsAction == 1)
        #expect(review.alarms == [.init(action: "DISPLAY", trigger: "15 minutes before the start", offset: -900)])

        let offsite = c.events[1]
        #expect(offsite.isAllDay)
        #expect(offsite.start?.isFloating == true)
        #expect(offsite.recurrence == "Monthly on the last Friday, until 2027-12-31")

        let local = c.events[2]
        #expect(local.start?.date == ISO8601DateFormatter().date(from: "2026-11-05T07:00:00Z"))
        #expect(local.end?.date == nil)
        #expect(local.end?.components.hour == 9)
        #expect(local.alarms.first?.trigger == "at the end")

        #expect(c.todos[0].isCompleted)
        #expect(c.todos[0].priority == 1)
        #expect(c.todos[0].due?.isUTC == true)

        #expect(codes(c.warnings) == ["calendar.procedureAlarm", "calendar.unknownTimeZone"])
        #expect(c.warnings.first { $0.code == "calendar.procedureAlarm" }?.level == .danger)
        #expect(c.warnings.first { $0.code == "calendar.unknownTimeZone" }?.reason.contains("Mars/Olympus") == true)
        #expect(EverydayDocument.calendar(c).headline == "Team")
        #expect(c.facts.contains(EverydayFact("Kind", "Invitation")))
    }

    @Test func recurrenceRulesInPlainWords() {
        #expect(EverydayCalendar.describeRule("FREQ=DAILY") == "Daily")
        #expect(EverydayCalendar.describeRule("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR") == "Weekly on weekdays")
        #expect(EverydayCalendar.describeRule("FREQ=YEARLY;BYMONTH=3;BYMONTHDAY=15;COUNT=1") == "Yearly in March on day 15, once")
        #expect(EverydayCalendar.describeRule("FREQ=MONTHLY;INTERVAL=3;BYDAY=1MO,TU") == "Every 3 months on the first Monday and Tuesday")
        #expect(EverydayCalendar.describeRule("FREQ=WEEKLY;BYHOUR=9") == "Weekly (with further rules)")
        #expect(EverydayCalendar.describeRule("INTERVAL=2") == nil)
        #expect(EverydayCalendar.describeRule("FREQ=FORTNIGHTLY") == nil)
        #expect(EverydayCalendar.parseDuration("-P1DT2H") == -93_600)
        #expect(EverydayCalendar.parseDuration("P2W") == 1_209_600)
        #expect(EverydayCalendar.parseDuration("PT") == nil)
    }

    @Test func calendarWindowsZoneAndMalformedInput() throws {
        let windows = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Call\nDTSTART;TZID=Eastern Standard Time:20260115T100000\nEND:VEVENT\nEND:VCALENDAR\n"
        guard case .calendar(let w)? = read(windows, "call.ics") else { throw Failure("windows zone") }
        #expect(w.events[0].start?.date == ISO8601DateFormatter().date(from: "2026-01-15T15:00:00Z"))
        #expect(w.warnings.isEmpty)
        #expect(EverydayDocument.calendar(w).headline == "Call")

        let broken = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Cut short\nDTSTART:2026\nDTEND:20260101T100000Z\n"
        guard case .calendar(let b)? = read(broken, "broken.ics") else { throw Failure("broken calendar") }
        #expect(b.eventCount == 1)
        #expect(codes(b.warnings) == ["calendar.missingStart", "calendar.malformed"])

        let backwards = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART:20260101T100000Z\nDTEND:20260101T090000Z\nEND:VEVENT\nEND:VCALENDAR"
        guard case .calendar(let r)? = read(backwards, "r.ics") else { throw Failure("backwards") }
        #expect(codes(r.warnings) == ["calendar.endBeforeStart"])
    }

    // MARK: Contacts

    static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]

    static var vcf: String {
        [
            "BEGIN:VCARD", "VERSION:3.0", "FN:Ana Lima", "N:Lima;Ana;María;Dr.;", "ORG:Acme Example;Research",
            "TITLE:Lead Scientist", "EMAIL;TYPE=INTERNET,WORK,PREF:ana@acme.example", "TEL;TYPE=CELL:+1 555 0100",
            "ADR;TYPE=WORK:;;1 Example Way;Springfield;ST;12345;Exampleland", "BDAY:19900214",
            "PHOTO;ENCODING=b;TYPE=JPEG:" + Data(jpeg).base64EncodedString(), "NOTE:Met at the\\, conference", "END:VCARD",
            "BEGIN:VCARD", "VERSION:2.1", "N;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:Okafor;Bo=C3=A9",
            "FN;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:Bo=C3=A9 Oka=", "for", "TEL;WORK;VOICE:555-0101",
            "EMAIL;INTERNET:bo@acme.example", "END:VCARD",
            "BEGIN:VCARD", "VERSION:4.0", "FN:Cy Chen", "PHOTO:data:image/png;base64,iVBORw0KGgo=", "BDAY:--0315",
            "item1.URL:https://acme.example/cy", "END:VCARD",
        ].joined(separator: "\r\n")
    }

    @Test func vcardVersionsEncodingsAndPhotos() throws {
        guard case .contacts(let c)? = read(Self.vcf, "people.vcf") else { throw Failure("not contacts") }
        #expect(c.cardCount == 3)
        let ana = c.cards[0]
        #expect(ana.version == "3.0")
        #expect(ana.displayName == "Ana Lima")
        #expect(ana.name == .init(family: "Lima", given: "Ana", additional: "María", prefix: "Dr.", suffix: nil))
        #expect(ana.organization == "Acme Example" && ana.department == "Research")
        #expect(ana.title == "Lead Scientist")
        #expect(ana.emails == [.init(labels: ["work", "pref"], value: "ana@acme.example")])
        #expect(ana.phones == [.init(labels: ["cell"], value: "+1 555 0100")])
        #expect(ana.addresses.first?.street == "1 Example Way")
        #expect(ana.addresses.first?.country == "Exampleland")
        #expect(ana.addresses.first?.formatted == "1 Example Way\n12345 Springfield ST\nExampleland")
        #expect(ana.birthday == "1990-02-14")
        #expect(ana.photo?.data == Data(Self.jpeg))
        #expect(ana.photo?.mediaType == "image/jpeg")
        #expect(ana.note == "Met at the, conference")

        let bo = c.cards[1]
        #expect(bo.formattedName == "Boé Okafor")
        #expect(bo.name?.given == "Boé")
        #expect(bo.phones == [.init(labels: ["work"], value: "555-0101")])
        #expect(bo.emails.first?.value == "bo@acme.example")

        let cy = c.cards[2]
        #expect(cy.photo?.mediaType == "image/png")
        #expect(cy.photo?.byteCount == 8)
        #expect(cy.birthday == "--03-15")
        #expect(cy.urls.first?.value == "https://acme.example/cy")
        #expect(c.warnings.isEmpty)
        #expect(EverydayDocument.contacts(c).headline == "3 contacts")
    }

    @Test func vcardLargePhotoUnnamedAndUnterminated() throws {
        let big = Data(repeating: 0xAB, count: ContactsSummary.maxPhotoBytes + 10).base64EncodedString()
        let text = "BEGIN:VCARD\nVERSION:4.0\nFN:Dee Diaz\nPHOTO:data:image/jpeg;base64,\(big)\nEND:VCARD\nBEGIN:VCARD\nVERSION:3.0\nEMAIL:x@acme.example\n"
        guard case .contacts(let c)? = read(text, "big.vcf") else { throw Failure("big") }
        #expect(c.cardCount == 2)
        #expect(c.cards[0].photo?.data == nil)
        #expect(c.cards[0].photo?.byteCount == ContactsSummary.maxPhotoBytes + 10)
        #expect(c.cards[1].displayName == "x@acme.example")
        #expect(codes(c.warnings) == ["contacts.largePhoto", "contacts.unnamed", "contacts.unterminated"])
        #expect(EverydayDocument.contacts(.init(cards: [c.cards[0]], cardCount: 1, warnings: [], truncated: false)).headline == "Dee Diaz")
    }

    // MARK: Email

    static var eml: String {
        let subject = "=?UTF-8?B?" + Data("État de votre".utf8).base64EncodedString() + "?= =?UTF-8?Q?_compte?="
        let html = Data("<p>Café</p>".utf8).base64EncodedString()
        return [
            "Return-Path: <billing@evil.example>",
            "Authentication-Results: mx.acme.example; spf=fail smtp.mailfrom=evil.example;",
            "  dkim=none; dmarc=fail header.from=evil.example",
            "From: \"support@bank.example\" <billing@evil.example>",
            "To: Ana Lima <ana@acme.example>, \"Okafor, Bo\" <bo@acme.example>",
            "Cc: undisclosed-recipients:;",
            "Subject: \(subject)",
            "Date: Tue, 3 Nov 2026 09:30:00 +0100 (CET)",
            "Message-ID: <abc@evil.example>",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"outer\"",
            "",
            "preamble",
            "--outer",
            "Content-Type: multipart/alternative; boundary=\"inner\"",
            "",
            "--inner",
            "Content-Type: text/plain; charset=iso-8859-1",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            "Caf=E9 au lait=",
            " soon",
            "--inner",
            "Content-Type: text/html; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            html,
            "--inner--",
            "--outer",
            "Content-Type: application/pdf; name=\"statement.pdf\"",
            "Content-Disposition: attachment; filename*=utf-8''r%C3%A9sum%C3%A9.pdf",
            "Content-Transfer-Encoding: base64",
            "",
            Data("%PDF-1.4\n".utf8).base64EncodedString(),
            "--outer",
            "Content-Type: application/octet-stream",
            "Content-Disposition: attachment; filename=\"update.exe\"",
            "",
            "MZ",
            "--outer--",
            "",
        ].joined(separator: "\r\n")
    }

    @Test func emlHeadersBodiesAttachmentsAndPhishingHints() throws {
        guard case .email(let e)? = read(Self.eml, "message.eml") else { throw Failure("not email") }
        #expect(e.format == .eml)
        #expect(e.subject == "État de votre compte")
        #expect(e.from == .init(name: "support@bank.example", address: "billing@evil.example"))
        #expect(e.to == [.init(name: "Ana Lima", address: "ana@acme.example"), .init(name: "Okafor, Bo", address: "bo@acme.example")])
        #expect(e.cc.isEmpty)
        #expect(e.date == ISO8601DateFormatter().date(from: "2026-11-03T08:30:00Z"))
        #expect(e.messageID == "<abc@evil.example>")
        #expect(e.plainBody == "Café au lait soon")
        #expect(e.htmlBody == "<p>Café</p>")
        #expect(e.attachments.map(\.name) == ["résumé.pdf", "update.exe"])
        #expect(e.attachments.map(\.size) == [9, 2])
        #expect(e.attachments[0].mediaType == "application/pdf")
        #expect(e.parts.map(\.mediaType) == ["multipart/mixed", "multipart/alternative", "text/plain", "text/html",
                                              "application/pdf", "application/octet-stream"])
        #expect(e.parts.map(\.depth) == [0, 1, 2, 2, 1, 1])
        #expect(e.authentication == .init(server: "mx.acme.example", spf: "fail", dkim: "none", dmarc: "fail"))
        #expect(codes(e.warnings) == ["email.displayNameMismatch", "email.dmarcFail", "email.authFail", "email.riskyAttachment"])
        #expect(e.warnings.first { $0.code == "email.displayNameMismatch" }?.level == .caution)
        #expect(e.warnings.first { $0.code == "email.riskyAttachment" }?.reason.contains("update.exe") == true)
        #expect(e.headers.first { $0.label == "Subject" }?.value == "État de votre compte")
        #expect(EverydayDocument.email(e).headline == "État de votre compte")
        #expect(e.facts.contains(EverydayFact("Date", "2026-11-03T08:30:00Z")))
    }

    @Test func emlCleanMessageHasNoWarnings() throws {
        let text = "From: Ana Lima <ana@acme.example>\nTo: bo@acme.example (Bo Okafor)\nSubject: Lunch\nDate: 3 Nov 26 12:00 GMT\n"
            + "Authentication-Results: mx.acme.example; spf=pass; dkim=pass; dmarc=pass\n\nSee you at noon.\n"
        guard case .email(let e)? = read(text, "lunch.eml") else { throw Failure("clean") }
        #expect(e.warnings.isEmpty)
        #expect(e.to == [.init(name: "Bo Okafor", address: "bo@acme.example")])
        #expect(e.plainBody == "See you at noon.\n")
        #expect(e.date == ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z"))
        #expect(e.attachments.isEmpty)
        // A display name that carries the sender's own address is not a mismatch.
        let own = "From: \"ana@acme.example\" <ana@mail.acme.example>\nSubject: x\n\nbody"
        guard case .email(let o)? = read(own, "own.eml") else { throw Failure("own") }
        #expect(o.warnings.isEmpty)
    }

    @Test func emlMalformedAndDeepNesting() throws {
        var deep = "From: a@acme.example\nSubject: deep\nContent-Type: multipart/mixed; boundary=\"b0\"\n\n"
        for level in 1...20 { deep += "--b\(level - 1)\nContent-Type: multipart/mixed; boundary=\"b\(level)\"\n\n" }
        deep += "--b20\nContent-Type: text/plain\n\nbottom\n"
        guard case .email(let d)? = read(deep, "deep.eml") else { throw Failure("deep") }
        #expect(codes(d.warnings).contains("email.tooDeep"))
        #expect(d.truncated)

        let unclosed = "From: a@acme.example\nSubject: open\nContent-Type: multipart/mixed; boundary=zz\n\n--zz\nContent-Type: text/plain\n\nhello\n--zz\nContent-Disposition: attachment; filename=a.txt\n\nabc"
        guard case .email(let u)? = read(unclosed, "open.eml") else { throw Failure("unclosed") }
        #expect(u.plainBody == "hello")
        #expect(u.attachments.first?.name == "a.txt")
        #expect(read("no headers here at all", "x.eml") == nil)
    }

    @Test func rfc2047And2231Decoding() {
        #expect(EverydayMail.decodeWords("=?iso-8859-1?q?caf=E9?= ok") == "café ok")
        #expect(EverydayMail.decodeWords("=?utf-8?b?w6k=?= =?utf-8?b?w6k=?=") == "éé")
        #expect(EverydayMail.decodeWords("plain =?bogus") == "plain =?bogus")
        let p = EverydayMail.parameters("attachment; filename*0*=utf-8''na%C3%AF; filename*1=\"ve.txt\"")
        #expect(p.value == "attachment")
        #expect(p.params["filename"] == "naïve.txt")
    }

    // MARK: Outlook .msg

    static func msgFixture() -> [UInt8] {
        func utf16(_ s: String) -> [UInt8] { s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } }
        func props(header: Int, _ entries: [(UInt32, UInt64)]) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: header)
            for (tag, value) in entries {
                out += withUnsafeBytes(of: tag.littleEndian, Array.init)
                out += withUnsafeBytes(of: UInt32(6).littleEndian, Array.init)
                out += withUnsafeBytes(of: value.littleEndian, Array.init)
            }
            return out
        }
        // 2026-11-03T08:30:00Z as a FILETIME.
        let unix = ISO8601DateFormatter().date(from: "2026-11-03T08:30:00Z")!.timeIntervalSince1970
        let filetime = UInt64((Int64(unix) + 11_644_473_600) * 10_000_000)
        let headers = "Received: from mx.acme.example\r\nAuthentication-Results: mx.acme.example; spf=pass; dkim=pass; dmarc=pass\r\nDate: Tue, 3 Nov 2026 09:30:00 +0100\r\n"
        let pdf = [UInt8](repeating: 0x25, count: 5_000)        // over the mini-stream cutoff: regular sectors
        return CFBWriter.write(root: [
            .stream("__substg1.0_0037001F", utf16("Quarterly plan")),
            .stream("__substg1.0_0C1A001F", utf16("Ana Lima")),
            .stream("__substg1.0_0C1F001F", utf16("/O=ACME/OU=EXCHANGE/CN=ANA")),
            .stream("__substg1.0_5D01001F", utf16("ana@acme.example")),
            .stream("__substg1.0_1000001F", utf16("Hello team,\nSee attached.")),
            .stream("__substg1.0_007D001F", utf16(headers)),
            .stream("__properties_version1.0", props(header: 32, [(0x0039_0040, filetime)])),
            .storage("__recip_version1.0_#00000000", [
                .stream("__substg1.0_3001001F", utf16("Bo Okafor")),
                .stream("__substg1.0_39FE001F", utf16("bo@acme.example")),
                .stream("__properties_version1.0", props(header: 8, [(0x0C15_0003, 1)])),
            ]),
            .storage("__recip_version1.0_#00000001", [
                .stream("__substg1.0_3001001F", utf16("Cy Chen")),
                .stream("__substg1.0_3003001E", Array("cy@acme.example".utf8)),
                .stream("__properties_version1.0", props(header: 8, [(0x0C15_0003, 2)])),
            ]),
            .storage("__attach_version1.0_#00000000", [
                .stream("__substg1.0_3707001F", utf16("plan.pdf")),
                .stream("__substg1.0_370E001F", utf16("application/pdf")),
                .stream("__substg1.0_37010102", pdf),
            ]),
            .storage("__attach_version1.0_#00000001", [
                .stream("__substg1.0_3707001F", utf16("invoice.pdf.exe")),
                .stream("__substg1.0_37010102", [UInt8](repeating: 0x4D, count: 100)),
            ]),
        ])
    }

    @Test func outlookMsgPropertiesRecipientsAndAttachments() throws {
        let bytes = Self.msgFixture()
        guard case .email(let e)? = EverydayReader.read(data: Data(bytes), fileName: "plan.msg") else { throw Failure("not msg") }
        #expect(e.format == .msg)
        #expect(e.subject == "Quarterly plan")
        #expect(e.from == .init(name: "Ana Lima", address: "ana@acme.example"))
        #expect(e.sender == nil)
        #expect(e.to == [.init(name: "Bo Okafor", address: "bo@acme.example")])
        #expect(e.cc == [.init(name: "Cy Chen", address: "cy@acme.example")])
        #expect(e.date == ISO8601DateFormatter().date(from: "2026-11-03T08:30:00Z"))
        #expect(e.plainBody == "Hello team,\nSee attached.")
        #expect(e.attachments.map(\.name) == ["plan.pdf", "invoice.pdf.exe"])
        #expect(e.attachments.map(\.size) == [5_000, 100])
        #expect(e.attachments[0].mediaType == "application/pdf")
        #expect(e.authentication?.dmarc == "pass")
        #expect(e.dateText == "Tue, 3 Nov 2026 09:30:00 +0100")
        #expect(codes(e.warnings) == ["email.riskyAttachment"])
        // Sniffed without the extension too.
        if case .email? = EverydayReader.read(data: Data(bytes), fileName: "attachment") {} else { Issue.record("msg sniff") }
    }

    @Test func outlookMsgDamagedFilesNeverCrash() {
        let bytes = Self.msgFixture()
        for cut in stride(from: 0, to: bytes.count, by: 97) {
            _ = EverydayReader.read(data: Data(bytes.prefix(cut)), fileName: "cut.msg")
        }
        // A FAT whose chains loop back on themselves.
        var looped = bytes
        let fatStart = 512
        for i in 0..<128 {
            let at = fatStart + i * 4
            looped.replaceSubrange(at..<(at + 4), with: withUnsafeBytes(of: UInt32(i).littleEndian, Array.init))
        }
        _ = EverydayReader.read(data: Data(looped), fileName: "loop.msg")
        var rng = LCG(seed: 7)
        for _ in 0..<400 {
            var mutated = bytes
            for _ in 0..<8 { mutated[Int(rng.next() % UInt64(mutated.count))] = UInt8(truncatingIfNeeded: rng.next()) }
            _ = EverydayReader.read(data: Data(mutated), fileName: "fuzz.msg")
        }
    }

    // MARK: BibTeX

    static let bib = #"""
    @string{jex = "Journal of Examples"}
    @comment{ignored @article{nope, title={x}} }
    @article{lima2024,
      author = {Lima, Ana Mar{\'\i}a and Okafor, Bo and Chen, Cy},
      title = {A {Study} of Ex{\"a}mples},
      journal = jex # " Letters",
      year = 2024,
      volume = {12}, number = 3,
      pages = {45--67},
      month = mar
    }
    @inproceedings{vanb2020,
      author = "Ludwig van Beethoven and others",
      title = "On Symphonies",
      booktitle = {Proceedings of Music},
      year = {2020}
    }
    @book{who2019, author = {{World Health Organization}}, title = {Report}, publisher = undefinedpub, year = 2019}
    @misc{lima2024, title = {Duplicate}}
    @article{broken, title = {Unclosed
    @book{after, editor = {Diaz, Dee}, title={After}, year=2001}
    """#

    @Test func bibtexEntriesMacrosAndCitations() throws {
        guard case .bibliography(let b)? = read(Self.bib, "refs.bib") else { throw Failure("not bibtex") }
        #expect(b.entryCount == 5)
        #expect(b.entries.map(\.key) == ["lima2024", "vanb2020", "who2019", "lima2024", "after"])
        #expect(b.macroCount == 1)
        let lima = b.entries[0]
        #expect(lima.type == "article")
        #expect(lima.field("journal") == "Journal of Examples Letters")
        #expect(lima.field("month") == "March")
        #expect(lima.field("number") == "3")
        #expect(lima.authors == ["Lima, Ana María", "Okafor, Bo", "Chen, Cy"])
        #expect(lima.citation == "Lima, A. M., Okafor, B., & Chen, C. (2024). A Study of Exämples. Journal of Examples Letters, 12(3), 45–67.")
        #expect(b.entries[1].citation == "van Beethoven, L., et al. (2020). On Symphonies. Proceedings of Music.")
        #expect(b.entries[2].citation == "World Health Organization (2019). Report. undefinedpub.")
        #expect(b.entries[3].citation == "(n.d.). Duplicate.")
        #expect(b.entries[4].citation == "Diaz, D. (Ed.) (2001). After.")
        #expect(codes(b.warnings) == ["bibtex.duplicateKey", "bibtex.undefinedMacro", "bibtex.syntax"])
        #expect(b.warnings.first { $0.code == "bibtex.undefinedMacro" }?.reason.contains("undefinedpub") == true)
        #expect(b.typeCounts.first == EverydayFact("article", "1") || b.typeCounts.first == EverydayFact("book", "2"))
        #expect(b.facts.contains(EverydayFact("Years", "2001–2024")))
        #expect(EverydayDocument.bibliography(b).headline == "5 references")
    }

    @Test func bibtexNamesAndInitials() {
        #expect(EverydayBibTeX.shortName("Jean-Paul Sartre") == "Sartre, J.-P.")
        #expect(EverydayBibTeX.shortName("Doe, Jr., John") == "Doe, Jr., J.")
        #expect(EverydayBibTeX.shortName("{\\'E}mile Zola") == "Zola, É.")
        #expect(EverydayBibTeX.splitNames("A and B AND C and{} D").count == 3)
    }

    // MARK: LaTeX

    static let tex = #"""
    \documentclass[11pt,a4paper]{article}
    \usepackage[utf8]{inputenc}
    \usepackage{amsmath, graphicx}
    \title{An Example \\ Paper}
    \author{Ana Lima \thanks{Acme} \and Bo Okafor}
    \date{November 2026}
    \begin{document}
    \maketitle
    % a comment with \section{Not real}
    \section{Introduction}
    This is 50\% of the text, cited \cite{lima2024, vanb2020} and \citep[p.~3]{who2019}.
    \subsection*{Background}
    Math $a + b = c$ is skipped, and so is
    \begin{equation}
    E = mc^2
    \end{equation}
    \begin{figure}
    \includegraphics{plot.png}
    \caption{A plot}
    \end{figure}
    \begin{table}\end{table}
    \input{chapters/one}
    \include{/etc/secrets}
    \immediate\write18{rm -rf /}
    \bibliography{refs}
    \end{document}
    """#

    @Test func latexStructureCitationsInputsAndWords() throws {
        guard case .latex(let l)? = read(Self.tex, "paper.tex") else { throw Failure("not latex") }
        #expect(l.documentClass == "article")
        #expect(l.classOptions == ["11pt", "a4paper"])
        #expect(l.packages == [.init(name: "inputenc", options: ["utf8"]), .init(name: "amsmath", options: []), .init(name: "graphicx", options: [])])
        #expect(l.title == "An Example Paper")
        #expect(l.author == "Ana Lima, Bo Okafor")
        #expect(l.date == "November 2026")
        #expect(l.outline == [.init(level: .section, title: "Introduction", isStarred: false),
                              .init(level: .subsection, title: "Background", isStarred: true)])
        #expect(l.citeKeys == ["lima2024", "vanb2020", "who2019"])
        #expect(l.citationCount == 2)
        #expect(l.inputs == ["chapters/one", "/etc/secrets"])
        #expect(l.bibliographies == ["refs"])
        #expect(l.figureCount == 1 && l.tableCount == 1 && l.graphicsCount == 1)
        // This is 50 of the text cited and / Introduction / Background / Math is skipped and so is / A plot
        #expect(l.wordCount == 18)
        #expect(codes(l.warnings) == ["latex.shellEscape", "latex.readsOutside"])
        #expect(l.warnings.first { $0.code == "latex.shellEscape" }?.level == .danger)
        #expect(EverydayDocument.latex(l).headline == "An Example Paper")
    }

    @Test func latexMalformedAndMinimal() throws {
        guard case .latex(let l)? = read("\\documentclass{book}\n\\chapter{Open {brace\n", "draft.tex") else { throw Failure("malformed") }
        #expect(codes(l.warnings) == ["latex.unbalancedBraces", "latex.noDocument"])
        #expect(EverydayDocument.latex(l).headline == "LaTeX book document")
        guard case .latex(let m)? = read("Plain words only \\emph{here}.", "note.tex") else { throw Failure("minimal") }
        #expect(m.wordCount == 4)
        #expect(read("no commands at all", "x.tex") == nil)
    }

    // MARK: Robustness

    @Test func everyFixtureSurvivesCutsAndMutations() {
        let fixtures: [(String, String)] = [
            (Self.srt, "a.srt"), (Self.vtt, "a.vtt"), (Self.ass, "a.ass"), (Self.ttml, "a.ttml"), (Self.lrc, "a.lrc"),
            (Self.ics, "a.ics"), (Self.vcf, "a.vcf"), (Self.eml, "a.eml"), (Self.bib, "a.bib"), (Self.tex, "a.tex"),
        ]
        var rng = LCG(seed: 42)
        for (text, name) in fixtures {
            let bytes = [UInt8](text.utf8)
            for cut in stride(from: 0, to: bytes.count, by: max(1, bytes.count / 40)) {
                _ = EverydayReader.read(data: Data(bytes.prefix(cut)), fileName: name)
            }
            for _ in 0..<100 {
                var mutated = bytes
                for _ in 0..<4 { mutated[Int(rng.next() % UInt64(mutated.count))] = UInt8(truncatingIfNeeded: rng.next()) }
                _ = EverydayReader.read(data: Data(mutated), fileName: name)
            }
        }
    }

    @Test func pathologicalNestingAndSizeCap() throws {
        let braces = String(repeating: "{", count: 200_000)
        _ = read("@article{k, title = " + braces, "deep.bib")
        _ = read("\\documentclass{article}\\begin{document}" + braces, "deep.tex")
        _ = read("<tt>" + String(repeating: "<div>", count: 5_000), "deep.ttml")
        _ = read("BEGIN:VCALENDAR\n" + String(repeating: "BEGIN:VEVENT\n", count: 10_000), "deep.ics")
        _ = read(String(repeating: "--b\n", count: 50_000), "deep.eml")
        // Unclosed markup that a naive reader would search again and again (quadratic): these must stay linear.
        let angles = try subtitles("1\n00:00:01,000 --> 00:00:02,000\n" + String(repeating: "<{\\", count: 400_000) + "\n", "angles.srt")
        #expect(angles.cueCount == 1)
        guard case .latex(let cites)? = read(String(repeating: "\\cite[\\section{", count: 200_000), "cites.tex") else {
            throw Failure("cites")
        }
        #expect(cites.truncated)

        var big = Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n\n".utf8)
        big.append(Data(repeating: 0x20, count: EverydayReader.maxBytes))
        guard case .subtitles(let s)? = EverydayReader.read(data: big, fileName: "big.srt") else { throw Failure("big") }
        #expect(s.truncated)
        #expect(s.cueCount == 1)
    }
}

/// A deterministic random source for the mutation tests.
struct LCG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 11
    }
}

/// A minimal compound-file (CFB v3) writer for the .msg fixture: 512-byte sectors, a mini stream for streams under
/// 4,096 bytes, siblings chained through right pointers, at most 109 FAT sectors (no DIFAT).
enum CFBWriter {
    indirect enum Node {
        case stream(String, [UInt8])
        case storage(String, [Node])
    }

    struct Entry {
        var name: String
        var type: UInt8
        var data: [UInt8] = []
        var left: UInt32 = 0xFFFF_FFFF
        var right: UInt32 = 0xFFFF_FFFF
        var child: UInt32 = 0xFFFF_FFFF
        var start: UInt32 = 0xFFFF_FFFE
        var size: UInt64 = 0
    }

    static func write(root children: [Node]) -> [UInt8] {
        var entries = [Entry(name: "Root Entry", type: 5)]
        func add(_ nodes: [Node], parent: Int) {
            var previous: Int?
            for node in nodes {
                let index = entries.count
                switch node {
                case .stream(let name, let data):
                    entries.append(Entry(name: name, type: 2, data: data, size: UInt64(data.count)))
                case .storage(let name, _):
                    entries.append(Entry(name: name, type: 1))
                }
                if let previous { entries[previous].right = UInt32(index) } else { entries[parent].child = UInt32(index) }
                previous = index
                if case .storage(_, let inner) = node { add(inner, parent: index) }
            }
        }
        add(children, parent: 0)

        // Mini stream and mini FAT.
        var mini: [UInt8] = []
        var miniFAT: [UInt32] = []
        var big: [Int] = []
        for i in entries.indices where entries[i].type == 2 {
            if entries[i].data.count < 4096 {
                guard !entries[i].data.isEmpty else { continue }
                let first = mini.count / 64
                let sectors = (entries[i].data.count + 63) / 64
                entries[i].start = UInt32(first)
                mini += entries[i].data + [UInt8](repeating: 0, count: sectors * 64 - entries[i].data.count)
                for s in 0..<sectors { miniFAT.append(s == sectors - 1 ? 0xFFFF_FFFE : UInt32(first + s + 1)) }
            } else {
                big.append(i)
            }
        }
        func sectors(_ bytes: Int) -> Int { (bytes + 511) / 512 }
        let dirSectors = sectors(entries.count * 128)
        let miniFATSectors = sectors(miniFAT.count * 4)
        let miniSectors = sectors(mini.count)
        let bigSectors = big.map { sectors(entries[$0].data.count) }
        let others = dirSectors + miniFATSectors + miniSectors + bigSectors.reduce(0, +)
        var fatSectors = 1
        while fatSectors * 128 < fatSectors + others { fatSectors += 1 }

        var fat = [UInt32](repeating: 0xFFFF_FFFF, count: fatSectors * 128)
        var next = 0
        func chain(_ count: Int) -> UInt32 {
            guard count > 0 else { return 0xFFFF_FFFE }
            let first = next
            for s in 0..<count { fat[first + s] = s == count - 1 ? 0xFFFF_FFFE : UInt32(first + s + 1) }
            next += count
            return UInt32(first)
        }
        for s in 0..<fatSectors { fat[s] = 0xFFFF_FFFD }
        next = fatSectors
        let dirStart = chain(dirSectors)
        let miniFATStart = chain(miniFATSectors)
        let miniStart = chain(miniSectors)
        entries[0].start = mini.isEmpty ? 0xFFFF_FFFE : miniStart
        entries[0].size = UInt64(mini.count)
        for (k, i) in big.enumerated() { entries[i].start = chain(bigSectors[k]) }

        func le16(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func le64(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func pad(_ bytes: [UInt8]) -> [UInt8] { bytes + [UInt8](repeating: 0, count: (512 - bytes.count % 512) % 512) }

        var header: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + [UInt8](repeating: 0, count: 16)
        header += le16(0x3E) + le16(3) + le16(0xFFFE) + le16(9) + le16(6) + [UInt8](repeating: 0, count: 6)
        header += le32(0) + le32(UInt32(fatSectors)) + le32(dirStart) + le32(0) + le32(4096)
        header += le32(miniFAT.isEmpty ? 0xFFFF_FFFE : miniFATStart) + le32(UInt32(miniFATSectors))
        header += le32(0xFFFF_FFFE) + le32(0)
        for s in 0..<109 { header += le32(s < fatSectors ? UInt32(s) : 0xFFFF_FFFF) }

        var directory: [UInt8] = []
        for entry in entries {
            var name = Array(entry.name.utf16.prefix(31)).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            let nameLength = UInt16(name.count + 2)
            name += [UInt8](repeating: 0, count: 64 - name.count)
            directory += name + le16(nameLength) + [entry.type, 1] + le32(entry.left) + le32(entry.right) + le32(entry.child)
            directory += [UInt8](repeating: 0, count: 16) + le32(0) + le64(0) + le64(0) + le32(entry.start) + le64(entry.size)
        }

        var file = header
        file += fat.flatMap(le32)
        file += pad(directory)
        file += pad(miniFAT.flatMap(le32))
        file += pad(mini)
        for i in big { file += pad(entries[i].data) }
        return file
    }
}
