import Foundation

enum SelfTest {
    static func run() {
        let ics = """
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Test//EN
BEGIN:VEVENT
UID:one@test
DTSTART:20260901T150000Z
DTEND:20260901T153000Z
SUMMARY:Standup
LOCATION:https://meet.google.com/abc-defg-hij
DESCRIPTION:Zoom fallback https://zoom.us/j/987654321
END:VEVENT
BEGIN:VEVENT
UID:fold@test
DTSTART:20260905T100000Z
DTEND:20260905T103000Z
SUMMARY:Folded link
DESCRIPTION:Details at https://zoom.us/j/112223
 33 please
END:VEVENT
BEGIN:VEVENT
UID:rec@test
DTSTART;TZID=Europe/Berlin:20260824T090000
DTEND;TZID=Europe/Berlin:20260824T093000
SUMMARY:Weekly Sync
RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR
EXDATE;TZID=Europe/Berlin:20260826T090000
END:VEVENT
BEGIN:VEVENT
UID:rec@test
RECURRENCE-ID;TZID=Europe/Berlin:20260914T090000
DTSTART;TZID=Europe/Berlin:20260914T110000
DTEND;TZID=Europe/Berlin:20260914T113000
SUMMARY:Weekly moved
END:VEVENT
BEGIN:VEVENT
UID:urlprop@test
DTSTART:20260827T180000Z
DTEND:20260827T183000Z
SUMMARY:Link via URL prop
URL:https://teams.microsoft.com/l/meetup/1/xyz
END:VEVENT
BEGIN:VEVENT
UID:zoompwd@test
DTSTART:20260827T150000Z
DTEND:20260827T153000Z
SUMMARY:Zoom link only via URL prop
URL:https://us02web.zoom.us/j/12345?pwd=abc123
END:VEVENT
BEGIN:VEVENT
UID:allday@test
DTSTART;VALUE=DATE:20260902
SUMMARY:Away day
END:VEVENT
BEGIN:VEVENT
UID:cancel@test
DTSTART:20260903T100000Z
DTEND:20260903T110000Z
SUMMARY:Cancelled one
STATUS:CANCELLED
END:VEVENT
BEGIN:VEVENT
UID:altdesc@test
DTSTART:20260826T100000Z
DTEND:20260826T103000Z
SUMMARY:Outlook thing
DESCRIPTION:Agenda attached\\, see you there.
X-ALT-DESC;FMTTYPE=text/html:<html><body>Please join the meeting.<br>&#13;&#10;
 <a href="https://teams.microsoft.com/l/meetup-join/1/2/3">Join here</a></body></html>
END:VEVENT
BEGIN:VEVENT
UID:zoommtg@test
DTSTART:20260826T110000Z
DTEND:20260826T113000Z
SUMMARY:Native scheme conf
CONFERENCE;VALUE=URI:zoommtg://zoom.us/join?confno=123456789&pwd=abc123
END:VEVENT
BEGIN:VEVENT
UID:attach@test
DTSTART:20260826T120000Z
DTEND:20260826T123000Z
SUMMARY:RingCentral via attach
ATTACH:https://meetings.ringcentral.com/j/1667
END:VEVENT
BEGIN:VEVENT
UID:joiny@test
DTSTART:20260826T130000Z
DTEND:20260826T133000Z
SUMMARY:Internal bridge
DESCRIPTION:Join at https://meet.corp.example.com/join/42
END:VEVENT
BEGIN:VEVENT
UID:titlelink@test
DTSTART:20260826T140000Z
DTEND:20260826T143000Z
SUMMARY:Sync https://meet.internal.test/j/99
END:VEVENT
END:VCALENDAR
"""
        let utc = TimeZone(identifier: "UTC")!
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = utc
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        var berlinCalendar = Calendar(identifier: .gregorian)
        berlinCalendar.timeZone = berlin
        let subscription = CalendarSubscription(name: "Test", url: "https://example.com/cal.ics", colorIndex: 0)
        let runANow = utcCalendar.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 25, hour: 12))!
        let runBNow = utcCalendar.date(from: DateComponents(timeZone: utc, year: 2026, month: 9, day: 1, hour: 0))!
        let runA = ICSBuilder.meetings(fromICS: ics, subscription: subscription, now: runANow)
        let runB = ICSBuilder.meetings(fromICS: ics, subscription: subscription, now: runBNow)
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }
        let exdate = berlinCalendar.date(from: DateComponents(timeZone: berlin, year: 2026, month: 8, day: 26, hour: 9))!
        let overrideOriginal = berlinCalendar.date(from: DateComponents(timeZone: berlin, year: 2026, month: 9, day: 14, hour: 9))!
        let weeklyA = runA.filter { $0.uid == "rec@test" }
        let weeklyB = runB.filter { $0.uid == "rec@test" }
        expect(runA.contains { $0.uid == "one@test" && $0.link?.host == "meet.google.com" }, "single event with meet link")
        expect(runA.contains { $0.uid == "urlprop@test" && $0.link?.host == "teams.microsoft.com" }, "URL property link")
        expect(runA.first { $0.uid == "fold@test" }?.link?.absoluteString == "https://zoom.us/j/11222333", "folded line link")
        expect(weeklyA.count == 5, "weekly count run A is \(weeklyA.count), want 5")
        expect(!weeklyA.contains { abs($0.start.timeIntervalSince(exdate)) < 60 }, "exdate excluded")
        expect(weeklyB.count == 6, "weekly count run B is \(weeklyB.count), want 6")
        expect(weeklyB.contains { $0.title == "Weekly moved" }, "override present")
        expect(!weeklyB.contains { abs($0.start.timeIntervalSince(overrideOriginal)) < 60 }, "override replaced original")
        expect(!runA.contains { $0.uid == "cancel@test" }, "cancelled skipped")
        expect(!runA.contains { $0.uid == "allday@test" }, "all-day skipped")
        expect(runA.contains { $0.uid == "altdesc@test" && $0.link?.host == "teams.microsoft.com" }, "X-ALT-DESC teams link")
        expect(runA.first { $0.uid == "zoommtg@test" }?.link?.absoluteString == "https://zoom.us/j/123456789?pwd=abc123", "zoommtg conference converted")
        expect(runA.contains { $0.uid == "attach@test" && $0.link?.host == "meetings.ringcentral.com" }, "ATTACH ringcentral link")
        expect(runA.first { $0.uid == "joiny@test" }?.link?.host == "meet.corp.example.com", "join-path heuristic link")
        expect(runA.first { $0.uid == "titlelink@test" }?.link?.host == "meet.internal.test", "title fallback link")
        let zoomPwd = runA.first { $0.uid == "zoompwd@test" }
        expect(zoomPwd?.link?.absoluteString == "https://us02web.zoom.us/j/12345?pwd=abc123", "us02web zoom link with pwd")
        expect(zoomPwd?.link.flatMap { LinkExtractor.providerName(for: $0) } == "Zoom", "zoom provider name")
        expect(runB.contains { $0.uid == "one@test" }, "single event in run B")
        let crlf = ics.replacingOccurrences(of: "\n", with: "\r\n")
        let runC = ICSBuilder.meetings(fromICS: crlf, subscription: subscription, now: runANow)
        expect(runC.count == runA.count, "CRLF line endings parse identically (got \(runC.count), want \(runA.count))")

        // Native (EventKit) mapping — pure function, no EKEventStore, stays TCC-free.
        let nativeStart = Date(timeIntervalSince1970: 1_800_000_000)
        let nativeEnd = nativeStart.addingTimeInterval(1800)
        let nativeParsed = NativeCalendarSource.parsedEvent(
            uid: "EK-123",
            title: "Native standup",
            location: nil,
            notes: "Join at https://zoom.us/j/987654",
            url: nil,
            start: nativeStart,
            end: nativeEnd
        )
        let nativeLink = LinkExtractor.link(from: nativeParsed)
        expect(nativeLink?.host == "zoom.us", "native notes link extraction (got \(nativeLink?.host ?? "nil"))")
        expect(nativeParsed.durationSeconds == 1800, "native duration from end-start")
        expect(nativeParsed.rrule == nil && nativeParsed.exdates.isEmpty, "native events carry no recurrence data")
        expect(nativeParsed.status.isEmpty && !nativeParsed.isAllDay, "native defaults: not cancelled, not all-day")

        if failures.isEmpty {
            print("SELFTEST OK — runA \(runA.count) events, runB \(runB.count) events")
        } else {
            print("SELFTEST FAILED: \(failures.joined(separator: "; "))")
            exit(1)
        }
    }
}
