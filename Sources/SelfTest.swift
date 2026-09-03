import Foundation
import AppKit
import EventKit

enum SelfTest {
    /// Tiny assertion collector so test sections can share one failure report.
    struct Checker {
        var failures: [String] = []
        var notes: [String] = []
        mutating func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }
    }

    static func run() {
        var parser = Checker()
        parserTests(&parser)
        var durations = Checker()
        durationTests(&durations)
        var recurrence = Checker()
        recurrenceTests(&recurrence)
        var zones = Checker()
        zoneTests(&zones)
        var overrides = Checker()
        overrideTests(&overrides)
        var compliance = Checker()
        parserComplianceTests(&compliance)
        var links = Checker()
        linkRankingTests(&links)
        var reminders = Checker()
        reminderTests(&reminders)
        var settings = Checker()
        settingsTests(&settings)
        var fetch = Checker()
        fetchMergeTests(&fetch)
        var bookkeeping = Checker()
        bookkeepingTests(&bookkeeping)
        var filters = Checker()
        titleFilterTests(&filters)
        var updates = Checker()
        updateTests(&updates)
        let sections: [(String, Checker)] = [
            ("parser", parser), ("durations", durations), ("recurrence", recurrence), ("zones", zones),
            ("overrides", overrides), ("compliance", compliance), ("links", links), ("reminders", reminders),
            ("settings", settings), ("fetch", fetch), ("bookkeeping", bookkeeping), ("updates", updates), ("filters", filters),
        ]
        let all = sections.flatMap { $0.1.failures }
        if all.isEmpty {
            print("SELFTEST OK — \(parser.notes.joined(separator: ", ")); all suites green")
        } else {
            print("SELFTEST FAILED: \(all.joined(separator: "; "))")
            exit(1)
        }
    }

    // MARK: - Parser / ICS builder

    static func parserTests(_ c: inout Checker) {
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
        let runA = ICSBuilder.meetings(fromICS: ics, subscription: subscription, now: runANow).events
        let runB = ICSBuilder.meetings(fromICS: ics, subscription: subscription, now: runBNow).events
        let exdate = berlinCalendar.date(from: DateComponents(timeZone: berlin, year: 2026, month: 8, day: 26, hour: 9))!
        let overrideOriginal = berlinCalendar.date(from: DateComponents(timeZone: berlin, year: 2026, month: 9, day: 14, hour: 9))!
        let weeklyA = runA.filter { $0.uid == "rec@test" }
        let weeklyB = runB.filter { $0.uid == "rec@test" }
        c.notes.append("runA \(runA.count) events, runB \(runB.count) events")
        c.expect(runA.contains { $0.uid == "one@test" && $0.link?.host == "meet.google.com" }, "single event with meet link")
        c.expect(runA.contains { $0.uid == "urlprop@test" && $0.link?.host == "teams.microsoft.com" }, "URL property link")
        c.expect(runA.first { $0.uid == "fold@test" }?.link?.absoluteString == "https://zoom.us/j/11222333", "folded line link")
        c.expect(weeklyA.count == 5, "weekly count run A is \(weeklyA.count), want 5")
        c.expect(!weeklyA.contains { abs($0.start.timeIntervalSince(exdate)) < 60 }, "exdate excluded")
        c.expect(weeklyB.count == 6, "weekly count run B is \(weeklyB.count), want 6")
        c.expect(weeklyB.contains { $0.title == "Weekly moved" }, "override present")
        c.expect(!weeklyB.contains { abs($0.start.timeIntervalSince(overrideOriginal)) < 60 }, "override replaced original")
        c.expect(!runA.contains { $0.uid == "cancel@test" }, "cancelled skipped")
        c.expect(!runA.contains { $0.uid == "allday@test" }, "all-day skipped")
        c.expect(runA.contains { $0.uid == "altdesc@test" && $0.link?.host == "teams.microsoft.com" }, "X-ALT-DESC teams link")
        c.expect(runA.first { $0.uid == "zoommtg@test" }?.link?.absoluteString == "https://zoom.us/j/123456789?pwd=abc123", "zoommtg conference converted")
        c.expect(runA.contains { $0.uid == "attach@test" && $0.link?.host == "meetings.ringcentral.com" }, "ATTACH ringcentral link")
        c.expect(runA.first { $0.uid == "joiny@test" }?.link?.host == "meet.corp.example.com", "join-path heuristic link")
        c.expect(runA.first { $0.uid == "titlelink@test" }?.link?.host == "meet.internal.test", "title fallback link")
        let zoomPwd = runA.first { $0.uid == "zoompwd@test" }
        c.expect(zoomPwd?.link?.absoluteString == "https://us02web.zoom.us/j/12345?pwd=abc123", "us02web zoom link with pwd")
        c.expect(zoomPwd?.link.flatMap { LinkExtractor.providerName(for: $0) } == "Zoom", "zoom provider name")
        c.expect(runB.contains { $0.uid == "one@test" }, "single event in run B")
        // CRLF regression: compare full snapshots (ids, timestamps, titles, durations,
        // links), not just counts.
        let crlf = ics.replacingOccurrences(of: "\n", with: "\r\n")
        let runC = ICSBuilder.meetings(fromICS: crlf, subscription: subscription, now: runANow).events
        c.expect(runC.count == runA.count, "CRLF line endings parse identically (got \(runC.count), want \(runA.count))")
        c.expect(runC.map(\.id) == runA.map(\.id), "CRLF ids identical")
        c.expect(runC.map({ $0.start.timeIntervalSince1970 }) == runA.map({ $0.start.timeIntervalSince1970 })
            && runC.map({ $0.end.timeIntervalSince1970 }) == runA.map({ $0.end.timeIntervalSince1970 }), "CRLF timestamps identical")
        c.expect(runC.map(\.title) == runA.map(\.title), "CRLF titles identical")
        c.expect(runC.map(\.link) == runA.map(\.link), "CRLF links identical")

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
        c.expect(nativeLink?.host == "zoom.us", "native notes link extraction (got \(nativeLink?.host ?? "nil"))")
        c.expect(nativeParsed.durationSeconds == 1800, "native duration from end-start")
        c.expect(nativeParsed.rrule == nil && nativeParsed.exdates.isEmpty, "native events carry no recurrence data")
        c.expect(nativeParsed.status.isEmpty && !nativeParsed.isAllDay, "native defaults: not cancelled, not all-day")

        // Apple conference wrapper: description is decoration + join link only → link
        // extraction still works, but display suppresses the notes entirely.
        let appleNotes = "----( Video Call )----\nhttps://us02web.zoom.us/j/12345?pwd=12345\n---===---"
        let appleParsed = NativeCalendarSource.parsedEvent(
            uid: "apple-ek", title: "asdgadfgafdg", location: nil, notes: appleNotes,
            url: nil, start: nativeStart, end: nativeEnd
        )
        let appleLink = LinkExtractor.link(from: appleParsed)
        c.expect(appleLink?.absoluteString == "https://us02web.zoom.us/j/12345?pwd=12345", "apple wrapper link still extracted")
        c.expect(LinkExtractor.isJoinLinkOnlyText(appleNotes, link: appleLink), "apple wrapper notes suppressed")
        c.expect(LinkExtractor.isJoinLinkOnlyText(appleNotes + "\nBring slides", link: appleLink) == false, "wrapper + real notes still shown")
        c.expect(LinkExtractor.isJoinLinkOnlyText("Plain agenda\nsecond line", link: appleLink) == false, "plain notes never suppressed")
        c.expect(LinkExtractor.isDecorationLine("----( Video Call )----") && LinkExtractor.isDecorationLine("---===---"), "decoration lines recognized")
        c.expect(!LinkExtractor.isDecorationLine("( see doc )") && !LinkExtractor.isJoinLinkOnlyText("( see doc )", link: nil), "bare parenthetical is not decoration")

        // EventKit authorization aliases: `.authorized` and `.fullAccess` must both
        // read as readable, while `.writeOnly`/`.denied`/`.restricted`/`.notDetermined`
        // must not (they share raw values across SDKs, so compare rawValue sets).
        if #available(macOS 14.0, *) {
            c.expect(EKAuthorizationStatus.authorized.rawValue == EKAuthorizationStatus.fullAccess.rawValue, "authorized aliases fullAccess")
            let readable: Set<Int> = [EKAuthorizationStatus.authorized.rawValue, EKAuthorizationStatus.fullAccess.rawValue]
            let unreadable: Set<Int> = [EKAuthorizationStatus.writeOnly.rawValue, EKAuthorizationStatus.denied.rawValue, EKAuthorizationStatus.restricted.rawValue, EKAuthorizationStatus.notDetermined.rawValue]
            c.expect(readable.count == 1 && unreadable.count == 4 && readable.isDisjoint(with: unreadable), "authorization statuses disjoint")
        }
    }

    // MARK: - Durations

    static func durationTests(_ c: inout Checker) {
        // RFC timed durations used to fail entirely (the "T" marker hit the
        // numeric guard): PT30M, PT1H, P1DT2H must all parse now.
        c.expect(ICSParser.parseDuration("PT30M") == 1800, "PT30M")
        c.expect(ICSParser.parseDuration("PT1H") == 3600, "PT1H")
        c.expect(ICSParser.parseDuration("P1DT2H") == 93_600, "P1DT2H")
        c.expect(ICSParser.parseDuration("PT1M30S") == 90, "PT1M30S")
        c.expect(ICSParser.parseDuration("P2W") == 1_209_600, "P2W")
        c.expect(ICSParser.parseDuration("P1D") == 86_400, "P1D")
        c.expect(ICSParser.parseDuration("-PT15M") == -900, "-PT15M parses signed")
        // Zero / negative / malformed / unsupported values are invalid.
        c.expect(ICSParser.parseDuration("PT0S") == 0, "PT0S parses to zero (rejected at event level)")
        for bad in ["P1M", "P", "PT", "garbage", "", "P1D3H", "PT1D", "P0.5D", "PT10", "P1DT",
                    "P1W1D", "P1WT1H", "P1D1D", "PT1H1H", "PT1S1M", "PT1M1H"] {
            c.expect(ICSParser.parseDuration(bad) == nil, "invalid duration \(bad.isEmpty ? "(empty)" : bad) rejected")
        }
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let subscription = CalendarSubscription(name: "D", url: "https://d.example.com/cal.ics", colorIndex: 0)
        let now = cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 25, hour: 12))!
        func build(_ ics: String) -> [MeetingEvent] {
            ICSBuilder.meetings(fromICS: wrap(ics), subscription: subscription, now: now).events
        }
        // DURATION without DTEND drives the end time.
        let timed = build("""
        BEGIN:VEVENT
        UID:pt30m@test
        DTSTART:20260826T100000Z
        DURATION:PT30M
        SUMMARY:Half hour
        END:VEVENT
        BEGIN:VEVENT
        UID:p1dt2h@test
        DTSTART:20260826T110000Z
        DURATION:P1DT2H
        SUMMARY:Long one
        END:VEVENT
        BEGIN:VEVENT
        UID:negdur@test
        DTSTART:20260826T120000Z
        DURATION:-PT15M
        SUMMARY:Negative
        END:VEVENT
        BEGIN:VEVENT
        UID:p1m@test
        DTSTART:20260826T130000Z
        DURATION:P1M
        SUMMARY:Months are invalid
        END:VEVENT
        BEGIN:VEVENT
        UID:zeroend@test
        DTSTART:20260826T140000Z
        DTEND:20260826T140000Z
        SUMMARY:Zero length
        END:VEVENT
        BEGIN:VEVENT
        UID:revend@test
        DTSTART:20260826T150000Z
        DTEND:20260826T143000Z
        SUMMARY:End before start
        END:VEVENT
        END:VCALENDAR
        """.replacingOccurrences(of: "END:VCALENDAR\n        BEGIN", with: "BEGIN")) // placeholder, replaced below
        c.expect(timed.first { $0.uid == "pt30m@test" }.map { $0.end.timeIntervalSince($0.start) } == 1800, "PT30M event duration")
        c.expect(timed.first { $0.uid == "p1dt2h@test" }.map { $0.end.timeIntervalSince($0.start) } == 93_600, "P1DT2H event duration")
        c.expect(timed.first { $0.uid == "negdur@test" }.map { $0.end.timeIntervalSince($0.start) } == 3600, "negative duration falls back to default hour")
        c.expect(timed.first { $0.uid == "p1m@test" }.map { $0.end.timeIntervalSince($0.start) } == 3600, "invalid P1M falls back to default hour")
        c.expect(timed.first { $0.uid == "zeroend@test" }.map { $0.end.timeIntervalSince($0.start) } == 3600, "DTEND == DTSTART falls back to default hour")
        c.expect(timed.first { $0.uid == "revend@test" }.map { $0.end.timeIntervalSince($0.start) } == 3600, "DTEND < DTSTART falls back to default hour")
    }

    /// Wraps VEVENT bodies in a minimal VCALENDAR.
    static func wrap(_ events: String) -> String {
        """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Test//EN
        \(events)
        END:VCALENDAR
        """
    }

    // MARK: - Recurrence

    static func recurrenceTests(_ c: inout Checker) {
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let subscription = CalendarSubscription(name: "R", url: "https://r.example.com/cal.ics", colorIndex: 0)
        let now = cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 25, hour: 12))!
        let windowStart = now.addingTimeInterval(-6 * 3600)
        let windowEnd = now.addingTimeInterval(14 * 86400)
        func build(_ events: String, now: Date = now) -> (events: [MeetingEvent], warnings: [String]) {
            ICSBuilder.meetings(fromICS: wrap(events), subscription: subscription, now: now)
        }
        func dates(_ events: [MeetingEvent], uid: String) -> [Date] {
            events.filter { $0.uid == uid }.map(\.start)
        }

        // Unsupported frequencies never become daily recurrences: the event
        // keeps only its first occurrence and the feed warns.
        let hourly = build("""
        BEGIN:VEVENT
        UID:hourly@test
        DTSTART:20260826T100000Z
        DURATION:PT30M
        SUMMARY:Hourly
        RRULE:FREQ=HOURLY
        END:VEVENT
        END:VCALENDAR
        """.replacingOccurrences(of: "\n        END:VCALENDAR", with: ""))
        c.expect(dates(hourly.events, uid: "hourly@test").count == 1, "HOURLY never expands (got \(dates(hourly.events, uid: "hourly@test").count))")
        c.expect(hourly.warnings.contains { $0.contains("Unsupported RRULE") }, "HOURLY produces a warning")

        // COUNT from the anchor, exact.
        let counted = build("""
        BEGIN:VEVENT
        UID:count@test
        DTSTART:20260826T100000Z
        SUMMARY:Every other day x3
        RRULE:FREQ=DAILY;INTERVAL=2;COUNT=3
        END:VEVENT
        """)
        let countDates = dates(counted.events, uid: "count@test")
        c.expect(countDates.count == 3, "COUNT=3 yields 3 (got \(countDates.count))")
        c.expect(countDates.map { cal.component(.day, from: $0) } == [26, 28, 30], "interval honored with COUNT (got \(countDates.map { cal.component(.day, from: $0) }))")

        // UNTIL caps expansion.
        let until = build("""
        BEGIN:VEVENT
        UID:until@test
        DTSTART:20260826T100000Z
        SUMMARY:Daily until the 28th
        RRULE:FREQ=DAILY;UNTIL=20260828T100000Z
        END:VEVENT
        """)
        c.expect(dates(until.events, uid: "until@test").count == 3, "UNTIL inclusive (got \(dates(until.events, uid: "until@test").count))")

        // WKST decides week boundaries: anchored Sunday Aug 23 2026 with
        // BYDAY=SU,MO every 2nd week. WKST=SU weeks: Aug 23-29, Sep 6-12 →
        // Aug 24 (Mo), Sep 6, Sep 7 in-window. WKST=MO weeks: Aug 17-23,
        // Aug 31-Sep 6 → Aug 23 (Su, pre-window), Aug 31 (Mo), Sep 6 (Su).
        let wkstSU = build("""
        BEGIN:VEVENT
        UID:wkstsu@test
        DTSTART:20260823T100000Z
        SUMMARY:Biweekly SU weeks
        RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO;WKST=SU
        END:VEVENT
        """)
        let suDays = dates(wkstSU.events, uid: "wkstsu@test").map { cal.component(.day, from: $0) }.sorted()
        c.expect(suDays == [6, 7], "WKST=SU weekly set (got \(suDays))")
        let wkstMO = build("""
        BEGIN:VEVENT
        UID:wkstmo@test
        DTSTART:20260823T100000Z
        SUMMARY:Biweekly MO weeks
        RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=SU,MO;WKST=MO
        END:VEVENT
        """)
        let moDays = dates(wkstMO.events, uid: "wkstmo@test").map { cal.component(.day, from: $0) }.sorted()
        c.expect(moDays == [6, 31], "WKST=MO weekly set differs (got \(moDays))")

        // Monthly BYMONTHDAY incl. negative.
        let aug12Now = cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 12, hour: 12))!
        let monthly = build("""
        BEGIN:VEVENT
        UID:monthday@test
        DTSTART:20260815T100000Z
        SUMMARY:15th of the month
        RRULE:FREQ=MONTHLY;BYMONTHDAY=15
        END:VEVENT
        """, now: aug12Now)
        c.expect(dates(monthly.events, uid: "monthday@test").map { cal.component(.day, from: $0) } == [15], "BYMONTHDAY=15 monthly (got \(dates(monthly.events, uid: "monthday@test").map { cal.component(.day, from: $0) }))")
        let lastday = build("""
        BEGIN:VEVENT
        UID:lastday@test
        DTSTART:20260831T100000Z
        SUMMARY:Last day of the month
        RRULE:FREQ=MONTHLY;BYMONTHDAY=-1
        END:VEVENT
        """)
        c.expect(dates(lastday.events, uid: "lastday@test").map { cal.component(.day, from: $0) } == [31], "BYMONTHDAY=-1 last day (got \(dates(lastday.events, uid: "lastday@test").map { cal.component(.day, from: $0) }))")

        // Ordinal BYDAY: 1MO, -1FR, and plain MO (every Monday).
        let ordinal = build("""
        BEGIN:VEVENT
        UID:firstmo@test
        DTSTART:20260803T100000Z
        SUMMARY:First Monday
        RRULE:FREQ=MONTHLY;BYDAY=1MO
        END:VEVENT
        BEGIN:VEVENT
        UID:lastfr@test
        DTSTART:20260828T100000Z
        SUMMARY:Last Friday
        RRULE:FREQ=MONTHLY;BYDAY=-1FR
        END:VEVENT
        BEGIN:VEVENT
        UID:everymo@test
        DTSTART:20260803T100000Z
        SUMMARY:Every Monday
        RRULE:FREQ=MONTHLY;BYDAY=MO
        END:VEVENT
        """)
        c.expect(dates(ordinal.events, uid: "firstmo@test").map { cal.component(.day, from: $0) } == [7], "BYDAY=1MO → Sep 7 only (got \(dates(ordinal.events, uid: "firstmo@test").map { cal.component(.day, from: $0) }))")
        c.expect(dates(ordinal.events, uid: "lastfr@test").map { cal.component(.day, from: $0) } == [28], "BYDAY=-1FR → Aug 28 only (got \(dates(ordinal.events, uid: "lastfr@test").map { cal.component(.day, from: $0) }))")
        let everyMo = dates(ordinal.events, uid: "everymo@test")
        c.expect(everyMo.map { cal.component(.day, from: $0) } == [31, 7], "plain BYDAY=MO every Monday in window (got \(everyMo.map { cal.component(.day, from: $0) }))")

        // BYSETPOS: 1st and last of the MO/WE/FR set each month (window starts
        // Aug 25, so August's first-of-set is pre-window).
        let setpos = build("""
        BEGIN:VEVENT
        UID:setpos@test
        DTSTART:20260803T100000Z
        SUMMARY:Setpos
        RRULE:FREQ=MONTHLY;BYDAY=MO,WE,FR;BYSETPOS=1,-1
        END:VEVENT
        """)
        let setposDates = dates(setpos.events, uid: "setpos@test")
        let setposDays = setposDates.map { (cal.component(.month, from: $0), cal.component(.day, from: $0)) }
        c.expect(setposDays.contains(where: { $0 == (8, 31) }) && setposDays.contains(where: { $0 == (9, 2) }) && setposDays.count == 2, "BYSETPOS 1/-1 (got \(setposDays))")

        // Multiple BYxxx parts intersect before BYSETPOS is applied. In August
        // 2026 the second of {24 MO, 26 WE} is the 26th, not the unfiltered 25th.
        let intersected = build("""
        BEGIN:VEVENT
        UID:intersect@test
        DTSTART:20260803T100000Z
        SUMMARY:Intersected filters
        RRULE:FREQ=MONTHLY;BYMONTHDAY=24,25,26;BYDAY=MO,WE;BYSETPOS=2
        END:VEVENT
        """)
        c.expect(dates(intersected.events, uid: "intersect@test").map { cal.component(.day, from: $0) } == [26], "BYMONTHDAY/BYDAY intersect before BYSETPOS")

        // DTSTART is always recurrence occurrence one, regardless of filters.
        let mismatchedStart = build("""
        BEGIN:VEVENT
        UID:first@test
        DTSTART:20260826T100000Z
        SUMMARY:First despite filter
        RRULE:FREQ=MONTHLY;BYMONTHDAY=27;COUNT=2
        END:VEVENT
        BEGIN:VEVENT
        UID:firstexcluded@test
        DTSTART:20260826T110000Z
        SUMMARY:Excluded first
        RRULE:FREQ=MONTHLY;BYMONTHDAY=27;COUNT=2
        EXDATE:20260826T110000Z
        END:VEVENT
        """)
        c.expect(dates(mismatchedStart.events, uid: "first@test").map { cal.component(.day, from: $0) } == [26, 27], "DTSTART included when filters mismatch")
        c.expect(dates(mismatchedStart.events, uid: "firstexcluded@test").map { cal.component(.day, from: $0) } == [27], "EXDATE can remove mismatched DTSTART")

        // YEARLY with BYMONTH + ordinal BYDAY (2nd Tuesday of March) — view
        // the window from March 1.
        let marchNow = cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 3, day: 1, hour: 12))!
        let yearly = build("""
        BEGIN:VEVENT
        UID:secondTueMar@test
        DTSTART:20260310T100000Z
        SUMMARY:Second Tuesday of March
        RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2TU
        END:VEVENT
        """, now: marchNow)
        let yearlyDates = dates(yearly.events, uid: "secondTueMar@test")
        c.expect(yearlyDates.map { cal.component(.day, from: $0) } == [10], "yearly BYMONTH=3 BYDAY=2TU → Mar 10 (got \(yearlyDates.map { cal.component(.day, from: $0) }))")

        // YEARLY BYMONTHDAY without BYMONTH applies in every month, rather than
        // being implicitly restricted to DTSTART's month.
        let yearlyMonthDay = build("""
        BEGIN:VEVENT
        UID:yearmonthday@test
        DTSTART:20260127T100000Z
        SUMMARY:Every month in matching years
        RRULE:FREQ=YEARLY;BYMONTHDAY=27
        END:VEVENT
        """)
        let yearlyMonthDayParts = dates(yearlyMonthDay.events, uid: "yearmonthday@test").map { (cal.component(.month, from: $0), cal.component(.day, from: $0)) }
        c.expect(yearlyMonthDayParts.count == 1 && yearlyMonthDayParts.first.map { $0 == (8, 27) } == true, "YEARLY BYMONTHDAY applies outside DTSTART month (got \(yearlyMonthDayParts))")

        // Every scanned day consumes recurrence budget, including sparse
        // COUNT rules whose BYDAY rarely matches.
        if let sparse = ICSParser.makeEvent([
            ICSProperty(name: "UID", params: [:], value: "sparse@test"),
            ICSProperty(name: "DTSTART", params: [:], value: "20260801T100000Z"),
            ICSProperty(name: "RRULE", params: [:], value: "FREQ=DAILY;BYDAY=MO;COUNT=100"),
        ]) {
            var sparseBudget = 3
            _ = RRULEExpander.occurrences(of: sparse,
                windowStart: cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 1))!,
                windowEnd: cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 9, day: 30))!,
                budget: &sparseBudget)
            c.expect(sparseBudget == 0, "sparse recurrence scanning exhausts work budget")
        } else {
            c.expect(false, "sparse recurrence fixture parsed")
        }

        // A malformed numeric list invalidates the whole RRULE; valid elements
        // must not survive via compactMap.
        for text in ["FREQ=MONTHLY;BYMONTHDAY=1,x", "FREQ=MONTHLY;BYMONTHDAY=1,-9223372036854775808", "FREQ=YEARLY;BYMONTH=8,x", "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=1,x"] {
            c.expect(RRULE.parse(text, eventTz: utc) == nil, "malformed numeric RRULE list rejected: \(text)")
        }

        // Leap-day yearly: only leap years produce occurrences (2028 is next).
        let leap = build("""
        BEGIN:VEVENT
        UID:leap@test
        DTSTART:20240229T100000Z
        SUMMARY:Leap day
        RRULE:FREQ=YEARLY
        END:VEVENT
        """)
        c.expect(dates(leap.events, uid: "leap@test").isEmpty, "leap-day yearly skips non-leap years in window")

        // Exact window boundaries: start == windowStart kept, end == windowEnd kept,
        // one second outside dropped on both sides.
        let atStart = windowStart
        let atEnd = windowEnd
        let boundary = build("""
        BEGIN:VEVENT
        UID:atstart@test
        DTSTART:\(Self.icsStamp(atStart, tz: utc))
        SUMMARY:At window start
        END:VEVENT
        BEGIN:VEVENT
        UID:atend@test
        DTSTART:\(Self.icsStamp(atEnd, tz: utc))
        SUMMARY:At window end
        END:VEVENT
        BEGIN:VEVENT
        UID:before@test
        DTSTART:\(Self.icsStamp(atStart.addingTimeInterval(-1), tz: utc))
        SUMMARY:One second before
        END:VEVENT
        BEGIN:VEVENT
        UID:after@test
        DTSTART:\(Self.icsStamp(atEnd.addingTimeInterval(1), tz: utc))
        SUMMARY:One second after
        END:VEVENT
        """)
        c.expect(boundary.events.contains { $0.uid == "atstart@test" }, "event exactly at windowStart kept")
        c.expect(boundary.events.contains { $0.uid == "atend@test" }, "event exactly at windowEnd kept (not just same day)")
        c.expect(!boundary.events.contains { $0.uid == "before@test" }, "event 1s before windowStart dropped")
        c.expect(!boundary.events.contains { $0.uid == "after@test" }, "event 1s after windowEnd dropped")

        // Recurrence anchored decades ago must fast-forward instead of silently
        // disappearing (and must not burn the budget).
        let old = build("""
        BEGIN:VEVENT
        UID:oldweekly@test
        DTSTART:19950821T100000Z
        SUMMARY:Ancient weekly
        RRULE:FREQ=WEEKLY
        END:VEVENT
        """)
        let oldDates = dates(old.events, uid: "oldweekly@test")
        c.expect(!oldDates.isEmpty, "1995-anchored weekly still expands into the window")

        // Partial output must still warn when a COUNT rule exhausts its own
        // iteration budget before reaching the end of the fetch window.
        let limitedAnchor = now.addingTimeInterval(-19_995 * 86400)
        let partiallyLimited = build("""
        BEGIN:VEVENT
        UID:partialbudget@test
        DTSTART:\(Self.icsStamp(limitedAnchor, tz: utc))
        SUMMARY:Partially expanded
        RRULE:FREQ=DAILY;COUNT=30000
        END:VEVENT
        """)
        c.expect(!dates(partiallyLimited.events, uid: "partialbudget@test").isEmpty, "budget-limited recurrence can produce partial output")
        c.expect(partiallyLimited.warnings.contains { $0.contains("recurrence workload limit") }, "partial recurrence budget exhaustion warns")

        // The feed cap is enforced while emitting one large UID group, not
        // only between groups. Generate compact RDATE lines to avoid a fixture.
        var cappedBody = """
        BEGIN:VEVENT
        UID:capped@test
        DTSTART:20260826T000000Z
        SUMMARY:Large recurrence set

        """
        var stamps: [String] = []
        let capStart = cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 26))!
        for minute in 1...10_001 {
            stamps.append(Self.icsStamp(capStart.addingTimeInterval(TimeInterval(minute * 60)), tz: utc))
            if stamps.count == 400 {
                cappedBody += "RDATE:" + stamps.joined(separator: ",") + "\n"
                stamps.removeAll(keepingCapacity: true)
            }
        }
        if !stamps.isEmpty { cappedBody += "RDATE:" + stamps.joined(separator: ",") + "\n" }
        cappedBody += "END:VEVENT"
        let capped = build(cappedBody)
        c.expect(dates(capped.events, uid: "capped@test").count == ICSBuilder.maxEventsPerFeed, "single UID group capped at \(ICSBuilder.maxEventsPerFeed)")
        c.expect(capped.warnings.contains { $0.contains("more than \(ICSBuilder.maxEventsPerFeed) events") }, "single UID cap warns")

        // DST: a daily 02:30 Berlin meeting across the 2026-03-29 spring-forward
        // gap and the 2026-10-25 fall-back overlap yields exactly one occurrence
        // on each of those days (never zero, never two).
        var berlinCal = Calendar(identifier: .gregorian)
        berlinCal.timeZone = berlin
        let dstNow = berlinCal.date(from: DateComponents(timeZone: berlin, year: 2026, month: 3, day: 27, hour: 12))!
        let dst = build("""
        BEGIN:VEVENT
        UID:dstdaily@test
        DTSTART;TZID=Europe/Berlin:20260326T023000
        SUMMARY:Daily 2:30
        RRULE:FREQ=DAILY
        END:VEVENT
        """, now: dstNow)
        let dstDates = dates(dst.events, uid: "dstdaily@test")
        let gapDay = dstDates.filter { berlinCal.isDate($0, inSameDayAs: berlinCal.date(from: DateComponents(timeZone: berlin, year: 2026, month: 3, day: 29))!) }
        c.expect(gapDay.count == 1, "DST gap day has exactly one occurrence (got \(gapDay.count))")
        let overlapNow = berlinCal.date(from: DateComponents(timeZone: berlin, year: 2026, month: 10, day: 23, hour: 12))!
        let overlap = build("""
        BEGIN:VEVENT
        UID:dstover@test
        DTSTART;TZID=Europe/Berlin:20261022T023000
        SUMMARY:Daily 2:30 fall
        RRULE:FREQ=DAILY
        END:VEVENT
        """, now: overlapNow)
        let overlapDates = dates(overlap.events, uid: "dstover@test")
        let overlapDay = overlapDates.filter { berlinCal.isDate($0, inSameDayAs: berlinCal.date(from: DateComponents(timeZone: berlin, year: 2026, month: 10, day: 25))!) }
        c.expect(overlapDay.count == 1, "DST overlap day has exactly one occurrence (got \(overlapDay.count))")
        _ = windowStart
    }

    /// YYYYMMddTHHmmssZ stamp for an exact Date.
    static func icsStamp(_ date: Date, tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", comps.year!, comps.month!, comps.day!, comps.hour!, comps.minute!, comps.second!)
    }

    // MARK: - Time zones

    static func zoneTests(_ c: inout Checker) {
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let subscription = CalendarSubscription(name: "Z", url: "https://z.example.com/cal.ics", colorIndex: 0)
        let now = cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 25, hour: 12))!
        func build(_ events: String, now: Date = now) -> (events: [MeetingEvent], warnings: [String]) {
            ICSBuilder.meetings(fromICS: wrap(events), subscription: subscription, now: now)
        }
        // Windows/Outlook TZID maps to IANA.
        let windows = build("""
        BEGIN:VEVENT
        UID:winberlin@test
        DTSTART;TZID=W. Europe Standard Time:20260826T150000
        DURATION:PT30M
        SUMMARY:Outlook zone
        END:VEVENT
        """)
        let expected = cal.date(from: DateComponents(timeZone: TimeZone(identifier: "Europe/Berlin")!, year: 2026, month: 8, day: 26, hour: 15))
        c.expect(windows.events.first { $0.uid == "winberlin@test" }?.start == expected, "Windows TZID maps to Europe/Berlin instant")

        // Unknown TZID: event skipped with a visible warning (never shown in the
        // local zone), even when the feed defines its own VTIMEZONE for it.
        let unknown = build("""
        BEGIN:VTIMEZONE
        TZID:Custom/Weird
        BEGIN:STANDARD
        DTSTART:19700101T000000
        TZNAME:WET
        END:STANDARD
        END:VTIMEZONE
        BEGIN:VEVENT
        UID:weird@test
        DTSTART;TZID=Custom/Weird:20260826T150000
        SUMMARY:Unknown zone
        END:VEVENT
        BEGIN:VEVENT
        UID:unknown2@test
        DTSTART;TZID=Mars/Olympus:20260826T160000
        SUMMARY:Unknown zone 2
        END:VEVENT
        """)
        c.expect(unknown.events.filter { ["weird@test", "unknown2@test"].contains($0.uid) }.isEmpty, "unknown TZIDs skip events")
        c.expect(unknown.warnings.filter { $0.contains("unknown time zone") }.count == 2, "unknown TZIDs warn visibly (got \(unknown.warnings))")

        // TZID-less EXDATE inherits the master's zone: master is a
        // MO/WE/FR 09:00 Berlin series; the TZID-less EXDATE on Wednesday
        // Aug 26 must be read as Berlin 09:00 (= 07:00 UTC) and remove that
        // occurrence — a UTC interpretation would miss it entirely.
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let aug24Now = cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 24, hour: 12))!
        let inherit = build("""
        BEGIN:VEVENT
        UID:exinherit@test
        DTSTART;TZID=Europe/Berlin:20260824T090000
        SUMMARY:Weekly Berlin
        RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR
        EXDATE:20260826T090000
        END:VEVENT
        """)
        _ = aug24Now
        let berlinOccurrence = cal.date(from: DateComponents(timeZone: berlin, year: 2026, month: 8, day: 26, hour: 9))
        c.expect(!inherit.events.contains { $0.start == berlinOccurrence }, "TZID-less EXDATE inherits master zone and excludes the occurrence")
        c.expect(inherit.events.contains { $0.start == cal.date(from: DateComponents(timeZone: berlin, year: 2026, month: 8, day: 28, hour: 9))! }, "other occurrences survive")

        // TZID-less RECURRENCE-ID inherits the master zone too (window covers
        // Sep 14).
        let sep1Now = cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 9, day: 1, hour: 12))!
        let ridInherit = build("""
        BEGIN:VEVENT
        UID:ridinherit@test
        DTSTART;TZID=Europe/Berlin:20260824T090000
        DTEND;TZID=Europe/Berlin:20260824T093000
        SUMMARY:Weekly Berlin
        RRULE:FREQ=WEEKLY
        END:VEVENT
        BEGIN:VEVENT
        UID:ridinherit@test
        RECURRENCE-ID:20260914T090000
        DTSTART;TZID=Europe/Berlin:20260914T110000
        SUMMARY:Moved to 11
        END:VEVENT
        """, now: sep1Now)
        let original = cal.date(from: DateComponents(timeZone: berlin, year: 2026, month: 9, day: 14, hour: 9))!
        let moved = cal.date(from: DateComponents(timeZone: berlin, year: 2026, month: 9, day: 14, hour: 11))!
        c.expect(!ridInherit.events.contains { $0.start == original }, "TZID-less RECURRENCE-ID matched its Berlin occurrence")
        c.expect(ridInherit.events.contains { $0.start == moved }, "moved override present")
    }

    // MARK: - Overrides & revisions

    static func overrideTests(_ c: inout Checker) {
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let subscription = CalendarSubscription(name: "O", url: "https://o.example.com/cal.ics", colorIndex: 0)
        let now = cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 25, hour: 12))!
        func build(_ events: String) -> (events: [MeetingEvent], warnings: [String]) {
            ICSBuilder.meetings(fromICS: wrap(events), subscription: subscription, now: now)
        }

        // Detached overrides inherit omitted master data: title, location,
        // notes, link and duration.
        let inherited = build("""
        BEGIN:VEVENT
        UID:inherit@test
        DTSTART:20260826T100000Z
        DTEND:20260826T103000Z
        SUMMARY:Master title
        LOCATION:HQ
        DESCRIPTION:Agenda
        URL:https://zoom.us/j/555
        RRULE:FREQ=DAILY
        END:VEVENT
        BEGIN:VEVENT
        UID:inherit@test
        RECURRENCE-ID:20260827T100000Z
        DTSTART:20260827T140000Z
        END:VEVENT
        """)
        let movedEvent = inherited.events.first { $0.start == cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 27, hour: 14)) }
        c.expect(movedEvent?.title == "Master title", "override inherits title")
        c.expect(movedEvent?.location == "HQ", "override inherits location")
        c.expect(movedEvent?.notes == "Agenda", "override inherits notes")
        c.expect(movedEvent?.link?.absoluteString == "https://zoom.us/j/555", "override inherits link")
        c.expect(movedEvent.map { $0.end.timeIntervalSince($0.start) } == 1800, "override inherits duration")

        // A cancelled override without DTSTART (bare cancellation) removes the
        // occurrence and adds nothing.
        let cancelled = build("""
        BEGIN:VEVENT
        UID:cancelov@test
        DTSTART:20260826T100000Z
        DTEND:20260826T103000Z
        SUMMARY:Master
        RRULE:FREQ=DAILY
        END:VEVENT
        BEGIN:VEVENT
        UID:cancelov@test
        RECURRENCE-ID:20260827T100000Z
        STATUS:CANCELLED
        END:VEVENT
        """)
        let cancelledDate = cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 27, hour: 10))!
        c.expect(!cancelled.events.contains { $0.start == cancelledDate }, "bare cancelled override removes occurrence")
        c.expect(cancelled.events.contains { $0.start == cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 26, hour: 10))! }, "other occurrences survive bare cancellation")

        // An all-day detached override still suppresses its timed master
        // occurrence, but is not itself shown as a meeting.
        let allDayOverride = build("""
        BEGIN:VEVENT
        UID:alldayov@test
        DTSTART:20260826T100000Z
        SUMMARY:Timed master
        RRULE:FREQ=DAILY
        END:VEVENT
        BEGIN:VEVENT
        UID:alldayov@test
        RECURRENCE-ID:20260827T100000Z
        DTSTART;VALUE=DATE:20260827
        SUMMARY:All-day replacement
        END:VEVENT
        """)
        c.expect(!allDayOverride.events.contains { $0.uid == "alldayov@test" && cal.component(.day, from: $0.start) == 27 }, "all-day override suppresses timed occurrence and stays hidden")

        // Moved OUT of the window: the original occurrence disappears and the
        // override (outside) is not emitted.
        let movedOut = build("""
        BEGIN:VEVENT
        UID:outov@test
        DTSTART:20260826T100000Z
        SUMMARY:Master
        RRULE:FREQ=DAILY
        END:VEVENT
        BEGIN:VEVENT
        UID:outov@test
        RECURRENCE-ID:20260827T100000Z
        DTSTART:20261201T100000Z
        SUMMARY:Moved to December
        END:VEVENT
        """)
        c.expect(!movedOut.events.contains { $0.uid == "outov@test" && $0.start == cancelledDate }, "override moved out of window removes original")
        c.expect(!movedOut.events.contains { $0.title == "Moved to December" }, "override outside window not emitted")

        // Moved INTO the window: master occurrence originally outside the
        // window, override pulls it in.
        let movedIn = build("""
        BEGIN:VEVENT
        UID:inov@test
        DTSTART:20260826T100000Z
        SUMMARY:Master
        RRULE:FREQ=DAILY
        END:VEVENT
        BEGIN:VEVENT
        UID:inov@test
        RECURRENCE-ID:20260901T100000Z
        DTSTART:20260827T183000Z
        SUMMARY:Pulled into the window
        END:VEVENT
        """)
        c.expect(movedIn.events.contains { $0.title == "Pulled into the window" }, "override moved into window emitted")

        // Duplicate revisions: higher SEQUENCE wins; DTSTAMP breaks ties.
        let revisions = build("""
        BEGIN:VEVENT
        UID:rev@test
        SEQUENCE:1
        DTSTAMP:20260101T000000Z
        DTSTART:20260826T100000Z
        SUMMARY:Stale revision
        END:VEVENT
        BEGIN:VEVENT
        UID:rev@test
        SEQUENCE:2
        DTSTAMP:20260201T000000Z
        DTSTART:20260826T100000Z
        SUMMARY:Current revision
        END:VEVENT
        BEGIN:VEVENT
        UID:revov@test
        DTSTART:20260826T110000Z
        SUMMARY:Master two
        END:VEVENT
        BEGIN:VEVENT
        UID:revov@test
        SEQUENCE:1
        DTSTAMP:20260101T000000Z
        RECURRENCE-ID:20260826T110000Z
        DTSTART:20260826T120000Z
        SUMMARY:Stale override
        END:VEVENT
        BEGIN:VEVENT
        UID:revov@test
        SEQUENCE:2
        DTSTAMP:20260201T000000Z
        RECURRENCE-ID:20260826T110000Z
        DTSTART:20260826T130000Z
        SUMMARY:Current override
        END:VEVENT
        """)
        // rev@test master is single (no rrule): duplicate revisions must yield ONE event.
        c.expect(revisions.events.filter { $0.uid == "rev@test" }.count == 1, "duplicate master revisions deduplicated")
        c.expect(revisions.events.contains { $0.uid == "rev@test" && $0.title == "Current revision" }, "highest SEQUENCE master wins")
        c.expect(!revisions.events.contains { $0.title == "Stale override" }, "stale override revision dropped")
        c.expect(revisions.events.contains { $0.title == "Current override" }, "highest SEQUENCE override wins")

        // RDATE adds occurrences; one duplicating the generated occurrence
        // must not create a second card.
        let rdate = build("""
        BEGIN:VEVENT
        UID:rdate@test
        DTSTART:20260826T100000Z
        SUMMARY:Rdate master
        RRULE:FREQ=DAILY;COUNT=1
        RDATE:20260826T160000Z,20260827T100000Z,20260826T100000Z
        END:VEVENT
        """)
        let rdateDates = rdate.events.filter { $0.uid == "rdate@test" }.map(\.start)
        c.expect(rdateDates.count == 3, "RDATE adds dates, duplicates deduped (got \(rdateDates.count))")
        c.expect(rdateDates.contains(cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 26, hour: 16))!), "RDATE occurrence present")

        // RANGE=THISANDFUTURE overrides are rejected with a warning — the
        // master occurrence stays untouched.
        let range = build("""
        BEGIN:VEVENT
        UID:range@test
        DTSTART:20260826T100000Z
        SUMMARY:Range master
        RRULE:FREQ=DAILY
        END:VEVENT
        BEGIN:VEVENT
        UID:range@test
        RECURRENCE-ID;RANGE=THISANDFUTURE:20260827T100000Z
        DTSTART:20260827T120000Z
        SUMMARY:Range override
        END:VEVENT
        """)
        c.expect(range.warnings.contains { $0.contains("RANGE") }, "RANGE=THISANDFUTURE warns")
        c.expect(range.events.contains { $0.uid == "range@test" && $0.title == "Range master" && $0.start == cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 27, hour: 10))! }, "RANGE override ignored, master occurrence kept")
        c.expect(!range.events.contains { $0.title == "Range override" }, "RANGE override not applied one-off")

        // An override can replace DTSTART even when DTSTART did not satisfy the
        // master's BYMONTHDAY filter.
        let firstOverride = build("""
        BEGIN:VEVENT
        UID:firstov@test
        DTSTART:20260826T100000Z
        SUMMARY:Filtered master
        RRULE:FREQ=MONTHLY;BYMONTHDAY=27;COUNT=2
        END:VEVENT
        BEGIN:VEVENT
        UID:firstov@test
        RECURRENCE-ID:20260826T100000Z
        DTSTART:20260826T140000Z
        SUMMARY:Moved first
        END:VEVENT
        """)
        c.expect(!firstOverride.events.contains { $0.uid == "firstov@test" && $0.start == cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 26, hour: 10))! }, "override suppresses mismatched DTSTART")
        c.expect(firstOverride.events.contains { $0.uid == "firstov@test" && $0.title == "Moved first" }, "override replaces mismatched DTSTART")
    }

    // MARK: - Parser compliance

    static func parserComplianceTests(_ c: inout Checker) {
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let now = cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 25, hour: 12))!
        // Quoted parameters keep semicolons and colons; escaped quotes don't
        // derail the split.
        let quoted = ICSParser.splitProperty("ATTENDEE;CN=\"Smith: John\";ROLE=\"REQ;PARTICIPANT\":mailto:smith@example.com")
        c.expect(quoted?.name == "ATTENDEE", "quoted params: name parsed")
        c.expect(quoted?.value == "mailto:smith@example.com", "quoted params: value after unquoted colon")
        c.expect(quoted?.params["CN"] == "Smith: John", "quoted params: colon inside quotes preserved")
        c.expect(quoted?.params["ROLE"] == "REQ;PARTICIPANT", "quoted params: semicolon inside quotes preserved")
        let escapedQuote = ICSParser.splitProperty("ATTENDEE;CN=\"He said \\\"hi\\\"\":mailto:a@b.example")
        c.expect(escapedQuote?.value == "mailto:a@b.example", "escaped quotes: value still found")

        // Mixed-case component boundaries parse.
        let mixed = ICSBuilder.meetings(fromICS: wrap("""
        begin:vevent
        UID:mixed@test
        DTSTART:20260826T100000Z
        SUMMARY:Lowercase boundaries
        end:vevent
        """), subscription: CalendarSubscription(name: "M", url: "https://m.example.com/cal.ics", colorIndex: 0),
            now: cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 25, hour: 12))!).events
        c.expect(mixed.contains { $0.uid == "mixed@test" }, "mixed-case BEGIN/END:VEVENT accepted")

        // Left-to-right unescaping: a literal backslash before n survives.
        c.expect(ICSParser.unescape("a\\nb") == "a\nb", "escaped n → newline")
        c.expect(ICSParser.unescape("a\\\\nb") == "a\\nb", "escaped backslash + n stays literal (got \(ICSParser.unescape("a\\\\nb").debugDescription))")
        c.expect(ICSParser.unescape("a\\,b") == "a,b", "escaped comma")
        c.expect(ICSParser.unescape("a\\;b") == "a;b", "escaped semicolon")
        c.expect(ICSParser.unescape("x\\y") == "x\\y", "unknown escape preserved")
        c.expect(ICSParser.unescape("trailing\\") == "trailing\\", "trailing backslash preserved")

        // STATUS values are trimmed and case-insensitive: " CANCELLED "
        // (lowercase) still cancels.
        let statusFeed = ICSBuilder.meetings(fromICS: wrap("""
        BEGIN:VEVENT
        UID:spacedcancel@test
        DTSTART:20260826T100000Z
        SUMMARY:Padded cancel
        STATUS: CANCELLED
        END:VEVENT
        BEGIN:VEVENT
        UID:lowercancel@test
        DTSTART:20260826T110000Z
        SUMMARY:Lower cancel
        STATUS:cancelled
        END:VEVENT
        BEGIN:VEVENT
        UID:tentative@test
        DTSTART:20260826T120000Z
        SUMMARY:Tentative stays
        STATUS:TENTATIVE
        END:VEVENT
        """), subscription: CalendarSubscription(name: "S", url: "https://s.example.com/cal.ics", colorIndex: 0), now: now).events
        c.expect(!statusFeed.contains { $0.uid == "spacedcancel@test" }, "padded CANCELLED skips event")
        c.expect(!statusFeed.contains { $0.uid == "lowercancel@test" }, "lowercase cancelled skips event")
        c.expect(statusFeed.contains { $0.uid == "tentative@test" }, "TENTATIVE stays")

        // TZID parameters on ignored/non-date properties are inert. Only date
        // properties whose values are consumed can make an event unsafe.
        let ignoredTZID = ICSBuilder.meetings(fromICS: wrap("""
        BEGIN:VEVENT
        UID:ignoredtz@test
        DTSTART:20260826T130000Z
        SUMMARY;TZID=Mars/Olympus:TZID is irrelevant here
        END:VEVENT
        """), subscription: CalendarSubscription(name: "T", url: "https://t.example.com/cal.ics", colorIndex: 0), now: now)
        c.expect(ignoredTZID.events.contains { $0.uid == "ignoredtz@test" }, "unknown TZID on non-date property ignored")
        c.expect(!ignoredTZID.warnings.contains { $0.contains("unknown time zone") }, "irrelevant TZID does not warn")

        // Multiple conference properties: a garbage first value must not hide a
        // valid later one; ATTACH behaves the same.
        let multiConf = ICSParser.makeEvent([
            ICSProperty(name: "UID", params: [:], value: "multiconf@test"),
            ICSProperty(name: "DTSTART", params: [:], value: "20260826T100000Z"),
            ICSProperty(name: "CONFERENCE", params: [:], value: "not a url"),
            ICSProperty(name: "CONFERENCE", params: [:], value: "zoommtg://zoom.us/join?confno=42&pwd=x"),
            ICSProperty(name: "ATTACH", params: [:], value: "garbage"),
            ICSProperty(name: "ATTACH", params: [:], value: "https://meetings.ringcentral.com/j/9"),
        ])
        c.expect(multiConf?.conference == "zoommtg://zoom.us/join?confno=42&pwd=x", "first VALID conference wins over garbage")
        c.expect(multiConf?.attach == "https://meetings.ringcentral.com/j/9", "first VALID attach wins over garbage")
    }

    // MARK: - Link ranking

    static func linkRankingTests(_ c: inout Checker) {
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let inWindowNow = cal.date(from: DateComponents(timeZone: utc, year: 2026, month: 8, day: 25, hour: 12))!
        func link(_ ics: String) -> URL? {
            let events = ICSBuilder.meetings(fromICS: wrap(ics),
                subscription: CalendarSubscription(name: "L", url: "https://l.example.com/cal.ics", colorIndex: 0),
                now: inWindowNow).events
            return events.first?.link
        }
        // A known-provider non-join page (recording) is ignored; an actual join
        // link on an unknown host remains usable.
        let ranked = link("""
        BEGIN:VEVENT
        UID:rank@test
        DTSTART:20260826T100000Z
        SUMMARY:Recording vs bridge
        LOCATION:https://zoom.us/rec/share/xyz
        DESCRIPTION:Join at https://meet.corp.example.com/join/9
        END:VEVENT
        """)
        c.expect(ranked?.host == "meet.corp.example.com", "join URL on unknown host beats known-host non-join page (got \(ranked?.host ?? "nil"))")

        // Arbitrary URLs are event context, not Join actions — including URL:
        // properties and pages hosted by otherwise-known meeting providers.
        let unrelatedURLProperty = link("""
        BEGIN:VEVENT
        UID:unrelated-url@test
        DTSTART:20260826T100000Z
        SUMMARY:Read before planning
        URL:https://docs.example.com/planning/brief
        DESCRIPTION:Background at https://example.com/reference
        END:VEVENT
        """)
        c.expect(unrelatedURLProperty == nil, "unrelated URL property and notes links ignored")
        let providerRecording = link("""
        BEGIN:VEVENT
        UID:recording@test
        DTSTART:20260826T100000Z
        SUMMARY:Watch recording
        LOCATION:https://zoom.us/rec/share/xyz
        END:VEVENT
        """)
        c.expect(providerRecording == nil, "known-provider recording is not a meeting link")
        let providerHomepage = link("""
        BEGIN:VEVENT
        UID:homepage@test
        DTSTART:20260826T100000Z
        SUMMARY:https://zoom.us/support
        END:VEVENT
        """)
        c.expect(providerHomepage == nil, "known-provider support page is not a meeting link")

        // Structured CONFERENCE data is authoritative even for an internal
        // provider whose URL shape cannot be inferred safely.
        let structuredConference = link("""
        BEGIN:VEVENT
        UID:structured@test
        DTSTART:20260826T100000Z
        SUMMARY:Internal conference
        CONFERENCE;VALUE=URI:https://conference.corp.example/room/alpha
        END:VEVENT
        """)
        c.expect(structuredConference?.host == "conference.corp.example", "structured conference property trusted")

        // Provider-specific roots are accepted only when they have a plausible
        // room/code shape; generic internal join paths stay supported.
        c.expect(LinkExtractor.isMeetingLink(URL(string: "https://meet.google.com/abc-defg-hij")!), "Google Meet code accepted")
        c.expect(!LinkExtractor.isMeetingLink(URL(string: "https://meet.google.com/")!), "Google Meet homepage rejected")
        c.expect(LinkExtractor.isMeetingLink(URL(string: "https://company.example/join/42")!), "generic join path accepted")
        c.expect(!LinkExtractor.isMeetingLink(URL(string: "https://company.example/joining-notes")!), "join-like path substring rejected")
        c.expect(!LinkExtractor.isMeetingLink(URL(string: "https://company.example/meeting-agenda")!), "meeting prose path rejected")
        c.expect(LinkExtractor.isMeetingLink(URL(string: "https://us02web.zoom.us/my/alice")!), "Zoom personal room accepted")
        c.expect(!LinkExtractor.isMeetingLink(URL(string: "https://zoom.us/rec/share/xyz")!), "Zoom recording classifier rejected")
        let providerShapes = [
            "https://meet.goto.com/123456789",
            "https://meet.jit.si/EngineeringSync",
            "https://whereby.com/planning-room",
            "https://8x8.vc/company/room",
            "https://bluejeans.com/123456789",
            "https://meetings.dialpad.com/room/team-sync",
            "https://app.chime.aws/meetings/abc",
            "https://app.slack.com/huddle/T123/C456",
            "https://freeconferencecall.com/wall/alice",
        ]
        c.expect(providerShapes.allSatisfy { LinkExtractor.isMeetingLink(URL(string: $0)!) }, "supported provider join shapes accepted")
        c.expect(!LinkExtractor.isMeetingLink(URL(string: "https://bluejeans.com/products")!), "provider product page rejected")
        c.expect(!LinkExtractor.isMeetingLink(URL(string: "https://app.slack.com/client/T123/C456")!), "Slack channel page rejected")

        // Documented field priority: location beats description for equal
        // join-quality links; ATTACH ranks below both.
        let fieldOrder = link("""
        BEGIN:VEVENT
        UID:fieldorder@test
        DTSTART:20260826T100000Z
        SUMMARY:Field order
        LOCATION:https://zoom.us/j/111
        DESCRIPTION:https://zoom.us/j/222
        END:VEVENT
        """)
        c.expect(fieldOrder?.absoluteString == "https://zoom.us/j/111", "location outranks description")

        let attachLast = link("""
        BEGIN:VEVENT
        UID:attachlast@test
        DTSTART:20260826T100000Z
        SUMMARY:Attach last
        ATTACH:https://meetings.ringcentral.com/j/1667
        LOCATION:https://zoom.us/j/333
        END:VEVENT
        """)
        c.expect(attachLast?.host == "zoom.us", "location outranks ATTACH")

        // Google Meet links count as join links even without a /join path.
        let meet = link("""
        BEGIN:VEVENT
        UID:meetroot@test
        DTSTART:20260826T100000Z
        SUMMARY:Root join
        LOCATION:https://meet.google.com/abc-defg-hij
        DESCRIPTION:Also see https://zoom.us/j/444
        END:VEVENT
        """)
        c.expect(meet?.host == "meet.google.com", "meet.google.com root link counts as join, field order preserved")

        let zoom = URL(string: "https://us02web.zoom.us/j/2786283001?pwd=secret")!
        c.expect(LinkExtractor.displayLocation(zoom.absoluteString, link: zoom) == "Zoom", "URL-only location displays provider")
        c.expect(LinkExtractor.displayLocation("  Room 4  ", link: zoom) == "Room 4", "real location wins over provider")
        c.expect(LinkExtractor.displayLocation(nil, link: zoom) == "Zoom", "missing location falls back to provider")
        c.expect(LinkExtractor.displayLocation(nil, link: nil) == nil, "missing location and link stays absent")

        let mailOnly = link("""
        BEGIN:VEVENT
        UID:mailonly@test
        DTSTART:20260826T100000Z
        SUMMARY:Email the organizer
        DESCRIPTION:mailto:bob@example.com
        END:VEVENT
        """)
        c.expect(mailOnly == nil, "mailto detector result is not a join link")

        let phoneOnly = link("""
        BEGIN:VEVENT
        UID:phoneonly@test
        DTSTART:20260826T100000Z
        SUMMARY:Call the organizer
        DESCRIPTION:tel:+49123456789
        END:VEVENT
        """)
        c.expect(phoneOnly == nil, "tel detector result is not a join link")
    }

    // MARK: - Reminder scheduling & alert behavior

    static func reminderTests(_ c: inout Checker) {
        let cal = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ uid: String, startIn: TimeInterval, duration: TimeInterval) -> MeetingEvent {
            let start = now.addingTimeInterval(startIn)
            return MeetingEvent(uid: uid, title: uid, start: start, end: start.addingTimeInterval(duration),
                                location: nil, notes: nil, link: nil, calendarID: cal, calendarName: "Cal", colorIndex: 0)
        }

        // Normal delivery: inside the lead window, before start.
        let imminent = event("imminent", startIn: 120, duration: 1800)
        c.expect(AppStore.dueForAlert(events: [imminent], alerted: [], snoozed: [:], leadSeconds: 300, now: now).map(\.uid) == ["imminent"], "imminent event fires")

        // Too early: before the lead window.
        let early = event("early", startIn: 3600, duration: 1800)
        c.expect(AppStore.dueForAlert(events: [early], alerted: [], snoozed: [:], leadSeconds: 300, now: now).isEmpty, "pre-lead event does not fire")

        // Late delivery (wake / delayed launch / delayed refresh well after the
        // old 45-second cutoff): a RUNNING meeting still fires …
        let running = event("running", startIn: -300, duration: 1800)
        c.expect(AppStore.dueForAlert(events: [running], alerted: [], snoozed: [:], leadSeconds: 300, now: now).map(\.uid) == ["running"], "running meeting fires late")
        // … an ENDED meeting never does.
        let ended = event("ended", startIn: -3600, duration: 1800)
        c.expect(AppStore.dueForAlert(events: [ended], alerted: [], snoozed: [:], leadSeconds: 300, now: now).isEmpty, "ended meeting never fires")
        // The end boundary is exclusive for both first delivery and snooze.
        let atEnd = event("atend", startIn: -1800, duration: 1800)
        c.expect(AppStore.dueForAlert(events: [atEnd], alerted: [], snoozed: [:], leadSeconds: 300, now: now).isEmpty, "meeting at its end instant is over")
        c.expect(AppStore.dueForAlert(events: [atEnd], alerted: [atEnd.id], snoozed: [atEnd.id: now.addingTimeInterval(-5)], leadSeconds: 300, now: now).isEmpty, "snooze does not re-fire at meeting end")

        // Already alerted stays quiet; snooze re-fires on expiry while running.
        c.expect(AppStore.dueForAlert(events: [imminent], alerted: [imminent.id], snoozed: [:], leadSeconds: 300, now: now).isEmpty, "alerted event quiet")
        let snoozeExpired = [imminent.id: now.addingTimeInterval(-5)]
        c.expect(AppStore.dueForAlert(events: [imminent], alerted: [imminent.id], snoozed: snoozeExpired, leadSeconds: 300, now: now).map(\.uid) == ["imminent"], "expired snooze re-fires")
        let snoozePending = [imminent.id: now.addingTimeInterval(30)]
        c.expect(AppStore.dueForAlert(events: [imminent], alerted: [imminent.id], snoozed: snoozePending, leadSeconds: 300, now: now).isEmpty, "pending snooze quiet")

        // Active-meeting policy: defer before start, permanently dismiss from
        // the event start onward, and fail open for inactive/unknown states.
        let deferred = AppStore.meetingReminderDecision(due: [imminent], suppressionEnabled: true, activity: .meeting(.zoom), now: now)
        c.expect(deferred.present.isEmpty && deferred.dismiss.isEmpty, "active meeting defers an imminent event")
        let dismissed = AppStore.meetingReminderDecision(due: [running], suppressionEnabled: true, activity: .meeting(.zoom), now: now)
        c.expect(dismissed.present.isEmpty && dismissed.dismiss.map(\.uid) == ["running"], "active meeting dismisses a started event")
        let mixedSuppression = AppStore.meetingReminderDecision(due: [imminent, running], suppressionEnabled: true, activity: .meeting(.zoom), now: now)
        c.expect(mixedSuppression.present.isEmpty && mixedSuppression.dismiss.map(\.uid) == ["running"], "active meeting handles mixed start boundaries")
        c.expect(AppStore.meetingReminderDecision(due: [imminent], suppressionEnabled: true, activity: .inactive, now: now).present.count == 1, "inactive meeting detector presents")
        c.expect(AppStore.meetingReminderDecision(due: [imminent], suppressionEnabled: true, activity: .unknown, now: now).present.count == 1, "unknown meeting detector fails open")
        c.expect(AppStore.meetingReminderDecision(due: [imminent], suppressionEnabled: false, activity: .meeting(.zoom), now: now).present.count == 1, "disabled meeting suppression presents")

        // Newly due events merge into an open reminder instead of replacing it.
        let shown = event("shown", startIn: 60, duration: 1800)
        let merged = AlertController.mergedShown(existing: [shown], new: [shown, imminent])
        c.expect(merged.map(\.uid).sorted() == ["imminent", "shown"], "open alert merges new events, dedupes by id")

        // Reconciliation: removed/cancelled/disabled events drop; changed
        // events update; rescheduled (new id) cards drop.
        var changed = shown
        changed.colorHex = "#123456"
        let movedCopy = event("shown2", startIn: 600, duration: 1800)
        let reconciled = AlertController.reconciledShownEvents(shown: [shown, imminent], current: [changed, movedCopy])
        c.expect(reconciled.count == 1 && reconciled.first?.colorHex == "#123456", "reconciliation drops vanished events, updates changed ones")

        // Alert key classification.
        typealias Mod = NSEvent.ModifierFlags
        let plain: Mod = []
        c.expect(AlertController.keyAction(modifiers: plain, keyCode: 36, characters: "\r", snoozeable: true, hasFocusedControl: false) == .joinOrClose, "plain Return joins")
        c.expect(AlertController.keyAction(modifiers: plain, keyCode: 36, characters: "\r", snoozeable: true, hasFocusedControl: true) == .pressFocused, "focused control receives Return (pressed, not passed through)")
        c.expect(AlertController.keyAction(modifiers: .command, keyCode: 36, characters: "\r", snoozeable: true, hasFocusedControl: false) == .passThrough, "modified Return passes through")
        c.expect(AlertController.keyAction(modifiers: .shift, keyCode: 36, characters: "\r", snoozeable: true, hasFocusedControl: false) == .passThrough, "shift-Return passes through")
        c.expect(AlertController.keyAction(modifiers: plain, keyCode: 53, characters: nil, snoozeable: true, hasFocusedControl: false) == .close, "Escape closes")
        c.expect(AlertController.keyAction(modifiers: plain, keyCode: 36, characters: "\r", snoozeable: false, hasFocusedControl: false) == .joinOrClose, "Return without link closes")
        c.expect(AlertController.keyAction(modifiers: plain, keyCode: 6, characters: "s", snoozeable: true, hasFocusedControl: false) == .snooze, "plain s snoozes")
        c.expect(AlertController.keyAction(modifiers: plain, keyCode: 6, characters: "s", snoozeable: false, hasFocusedControl: false) == .swallow, "s with nothing running swallowed")
        c.expect(AlertController.keyAction(modifiers: .command, keyCode: 13, characters: "w", snoozeable: true, hasFocusedControl: false) == .swallow, "⌘W swallowed")
        c.expect(AlertController.keyAction(modifiers: .command, keyCode: 46, characters: "m", snoozeable: true, hasFocusedControl: false) == .swallow, "⌘M swallowed")
        c.expect(AlertController.keyAction(modifiers: plain, keyCode: 0, characters: "a", snoozeable: true, hasFocusedControl: false) == .passThrough, "other keys pass through")
        // Digits 1-9 join the Nth card; modified digits pass through.
        c.expect(AlertController.keyAction(modifiers: plain, keyCode: 18, characters: "1", snoozeable: true, hasFocusedControl: false) == .joinIndex(1), "plain 1 joins first card")
        c.expect(AlertController.keyAction(modifiers: plain, keyCode: 19, characters: "2", snoozeable: false, hasFocusedControl: false) == .joinIndex(2), "plain 2 joins second card")
        c.expect(AlertController.keyAction(modifiers: .command, keyCode: 18, characters: "1", snoozeable: true, hasFocusedControl: false) == .passThrough, "⌘1 passes through")
        c.expect(AlertController.keyAction(modifiers: plain, keyCode: 18, characters: "1", snoozeable: true, hasFocusedControl: true) == .joinIndex(1), "digits work with focused control too")

        // Mixed reminders: Return uses the first available link, while card
        // numbers preserve visual row identity and linkless rows do nothing.
        let joinURL = URL(string: "https://zoom.us/j/123")!
        let linkedStart = now.addingTimeInterval(60)
        let linked = MeetingEvent(uid: "linked", title: "Linked", start: linkedStart, end: linkedStart.addingTimeInterval(1800),
                                  location: nil, notes: nil, link: joinURL, calendarID: cal, calendarName: "Cal", colorIndex: 0)
        let mixed = [shown, linked, imminent]
        c.expect(AlertController.primaryJoinURL(in: mixed) == joinURL, "Return finds first available link in mixed reminder")
        c.expect(AlertController.indexedJoinURL(in: mixed, number: 1) == nil, "linkless card number has no action")
        c.expect(AlertController.indexedJoinURL(in: mixed, number: 2) == joinURL, "linked card number joins its row")
        c.expect(AlertController.indexedJoinURL(in: mixed, number: 4) == nil, "out-of-range card number has no action")

        let copiedDetails = MenuBarController.eventDetailsText(for: MeetingEvent(
            uid: "details", title: "Planning", start: now, end: now.addingTimeInterval(1800),
            location: "Room 4", notes: "Bring the draft", link: nil,
            calendarID: cal, calendarName: "Work", colorIndex: 0
        ))
        c.expect(copiedDetails.contains("Planning") && copiedDetails.contains("Calendar: Work") && copiedDetails.contains("Location: Room 4") && copiedDetails.contains("Notes: Bring the draft"), "linkless detail copy includes event context")

        // Keystroke guard: fresh timer-fired panels swallow keys for a fixed
        // window after appearing — in-flight typing must never join/snooze/close.
        c.expect(AlertController.keystrokeGuardActive(presentedAt: now.addingTimeInterval(-0.4), now: now, interval: 1.0), "guard active within the interval")
        c.expect(!AlertController.keystrokeGuardActive(presentedAt: now.addingTimeInterval(-1.0), now: now, interval: 1.0), "guard expired at the boundary")
        c.expect(!AlertController.keystrokeGuardActive(presentedAt: now.addingTimeInterval(-4), now: now, interval: 1.0), "guard long expired")

        // Tomorrow 09:00 across both DST transitions (Berlin): calendar
        // arithmetic, not +86,400 s.
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        var berlinCal = Calendar(identifier: .gregorian)
        berlinCal.timeZone = berlin
        let springEve = berlinCal.date(from: DateComponents(timeZone: berlin, year: 2026, month: 3, day: 28, hour: 23, minute: 30))!
        let springMorning = AppStore.nextMorning(after: springEve, calendar: berlinCal)
        let springComps = springMorning.map { berlinCal.dateComponents([.month, .day, .hour, .minute], from: $0) }
        c.expect(springComps?.month == 3 && springComps?.day == 29 && springComps?.hour == 9 && springComps?.minute == 0, "next morning across spring-forward is 09:00 (got \(String(describing: springComps)))")
        let fallEve = berlinCal.date(from: DateComponents(timeZone: berlin, year: 2026, month: 10, day: 24, hour: 23, minute: 30))!
        let fallMorning = AppStore.nextMorning(after: fallEve, calendar: berlinCal)
        let fallComps = fallMorning.map { berlinCal.dateComponents([.month, .day, .hour, .minute], from: $0) }
        c.expect(fallComps?.month == 10 && fallComps?.day == 25 && fallComps?.hour == 9 && fallComps?.minute == 0, "next morning across fall-back is 09:00 (got \(String(describing: fallComps)))")

        // Pause survives relaunch via Persisted round-trip.
        let pausedAt = now.addingTimeInterval(3600)
        let encoded = try? JSONEncoder().encode(Persisted(subscriptions: [], settings: AppSettings(), nativeCalendars: [], pausedUntil: pausedAt))
        let decoded = encoded.flatMap { try? JSONDecoder().decode(Persisted.self, from: $0) }
        c.expect(decoded?.pausedUntil == pausedAt, "pausedUntil persists")
        let legacy = try? JSONDecoder().decode(Persisted.self, from: Data("{\"subscriptions\":[],\"settings\":{}}".utf8))
        c.expect(legacy?.pausedUntil == nil, "legacy persisted state decodes without pausedUntil")
    }

    // MARK: - Settings & login item

    static func settingsTests(_ c: inout Checker) {
        c.expect(!AppStore.refreshIntervalChanged(from: 15, to: 15), "unrelated settings edits keep refresh cadence")
        c.expect(AppStore.refreshIntervalChanged(from: 15, to: 30), "refresh interval edit reschedules cadence")

        // Decoded settings are validated/clamped into the UI's offered ranges.
        let junk = """
        {"leadSeconds": -50, "refreshMinutes": 7, "soundName": "Nope", "lateMinutes": 9999, "skipDeclined": false}
        """
        let decoded = try? JSONDecoder().decode(AppSettings.self, from: Data(junk.utf8))
        c.expect(decoded?.leadSeconds == 0, "negative lead clamps to 0 (got \(String(describing: decoded?.leadSeconds)))")
        c.expect(decoded?.refreshMinutes == 5, "odd refresh interval snaps to 5 (got \(String(describing: decoded?.refreshMinutes)))")
        c.expect(decoded?.soundName == "Hero", "unknown sound falls back to Hero")
        c.expect(decoded?.lateMinutes == 60, "huge lateMinutes snaps to 60 (got \(String(describing: decoded?.lateMinutes)))")
        c.expect(decoded?.skipDeclined == false, "valid booleans preserved")
        c.expect(decoded?.automaticUpdateChecks == true && decoded?.skippedUpdateVersion == nil, "legacy settings use updater defaults")
        c.expect(decoded?.suppressRemindersDuringMeetings == false && decoded?.includeBrowserMeetings == false, "legacy settings disable meeting suppression")
        let upper = try? JSONDecoder().decode(AppSettings.self, from: Data("{\"leadSeconds\": 99999, \"refreshMinutes\": 45, \"lateMinutes\": -3}".utf8))
        c.expect(upper?.leadSeconds == 7200, "oversized lead clamps to 7200")
        c.expect(upper?.refreshMinutes == 30 || upper?.refreshMinutes == 60, "45 min snaps to a picker value (got \(String(describing: upper?.refreshMinutes)))")
        c.expect(upper?.lateMinutes == -1, "-3 snaps to -1 (got \(String(describing: upper?.lateMinutes)))")
        let extremes = try? JSONDecoder().decode(AppSettings.self, from: Data("{\"refreshMinutes\":-9223372036854775808,\"lateMinutes\":-9223372036854775808}".utf8))
        c.expect(extremes?.refreshMinutes == 5 && extremes?.lateMinutes == -1, "Int.min settings normalize without overflow")

        let zoomOwners = [MeetingAudioOwner(pid: 10, bundleID: "us.zoom.xos")]
        c.expect(MeetingActivityProbe.activity(owners: zoomOwners, includeBrowsers: false) == .meeting(.zoom), "Zoom input classifies as meeting")
        let teamsOwners = [MeetingAudioOwner(pid: 11, bundleID: "com.microsoft.teams2.helper")]
        c.expect(MeetingActivityProbe.activity(owners: teamsOwners, includeBrowsers: false) == .meeting(.teams), "Teams helper classifies as meeting")
        let chromeOwners = [MeetingAudioOwner(pid: 12, bundleID: "com.google.Chrome.helper")]
        c.expect(MeetingActivityProbe.activity(owners: chromeOwners, includeBrowsers: false) == .inactive, "browser input ignored by default")
        c.expect(MeetingActivityProbe.activity(owners: chromeOwners, includeBrowsers: true) == .meeting(.browser), "browser input classifies when opted in")
        let heliumOwners = [MeetingAudioOwner(pid: 14, bundleID: "net.imput.helium.helper")]
        c.expect(MeetingActivityProbe.activity(owners: heliumOwners, includeBrowsers: false) == .inactive, "Helium input ignored by default")
        c.expect(MeetingActivityProbe.activity(owners: heliumOwners, includeBrowsers: true) == .meeting(.browser), "Helium input classifies when opted in")
        let modernBrowserIDs = [
            "company.thebrowser.dia.helper",
            "company.thebrowser.Browser.helper",
            "com.brave.Browser.helper",
            "ai.perplexity.comet.helper",
            "com.openai.atlas.web",
            "com.browseros.BrowserOS.helper.renderer",
            "com.opera.Neon.helper",
            "org.ladybird.Ladybird",
            "org.chromium.Chromium.helper",
            "com.vivaldi.Vivaldi.helper",
            "com.kagi.kagimacOS.WebContent",
            "app.zen-browser.plugincontainer",
            "com.sigmaos.sigmaos.macos.WebContent",
            "com.duckduckgo.macos.browser.WebContent",
            "io.gitlab.librewolf-community.librewolf"
        ]
        for bundleID in modernBrowserIDs {
            let owners = [MeetingAudioOwner(pid: 15, bundleID: bundleID)]
            c.expect(MeetingActivityProbe.activity(owners: owners, includeBrowsers: true) == .meeting(.browser), "modern browser classifies: \(bundleID)")
        }
        let unrelatedOwners = [MeetingAudioOwner(pid: 13, bundleID: "com.example.recorder")]
        c.expect(MeetingActivityProbe.activity(owners: unrelatedOwners, includeBrowsers: true) == .inactive, "unknown input owner does not suppress")
        let unidentifiedOwners = [MeetingAudioOwner(pid: -1, bundleID: "")]
        c.expect(MeetingActivityProbe.activity(owners: unidentifiedOwners, includeBrowsers: true) == .unknown, "unidentified active input owner is unknown, not inactive")

        var debounce = MeetingActivityDebouncer()
        c.expect(debounce.apply(.meeting(.zoom)) == .meeting(.zoom), "positive meeting snapshot applies immediately")
        c.expect(debounce.apply(.inactive) == .meeting(.zoom), "first inactive snapshot is debounced")
        c.expect(debounce.apply(.inactive) == .inactive, "second inactive snapshot clears meeting")
        c.expect(debounce.apply(.meeting(.zoom)) == .meeting(.zoom) && debounce.apply(.unknown) == .unknown, "probe failure resets activity to unknown")

        var meetingSettings = AppSettings()
        meetingSettings.suppressRemindersDuringMeetings = true
        meetingSettings.includeBrowserMeetings = true
        let meetingData = try? JSONEncoder().encode(meetingSettings)
        let meetingRoundTrip = meetingData.flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
        c.expect(meetingRoundTrip?.suppressRemindersDuringMeetings == true && meetingRoundTrip?.includeBrowserMeetings == true, "meeting settings persist round-trip")

        // Palette positive modulo: any index (incl. extremes) maps without trapping.
        c.expect(Palette.nsColor(Int.min) == Palette.nsColor(Int.min % 10 + 10), "Int.min palette index safe")
        c.expect(Palette.nsColor(hex: "not-a-color") == Palette.nsColor(0), "invalid color hex falls back to default")
        c.expect(Palette.nsColor(hex: "#FF0000") == Palette.nsColor(hex: "FF0000"), "hex with/without # equivalent")

        // Login-item state mapping: enabled, disabled, externally disabled,
        // requires-approval, failure.
        typealias LIS = AppStore.LoginItemStatus
        c.expect(AppStore.resolvedLoginItemState(desired: true, failed: false, status: .enabled) == .enabled, "login enabled")
        c.expect(AppStore.resolvedLoginItemState(desired: false, failed: false, status: .notRegistered) == .disabled, "login disabled")
        c.expect(AppStore.resolvedLoginItemState(desired: false, failed: false, status: .enabled) == .enabled, "externally enabled wins over intent off")
        c.expect(AppStore.resolvedLoginItemState(desired: true, failed: false, status: .notRegistered) == .failed, "externally disabled shows failed")
        c.expect(AppStore.resolvedLoginItemState(desired: true, failed: false, status: .requiresApproval) == .requiresApproval, "requires approval")
        c.expect(AppStore.resolvedLoginItemState(desired: true, failed: true, status: .notRegistered) == .failed, "registration failure")
        c.expect(AppStore.resolvedLoginItemState(desired: false, failed: true, status: .enabled) == .failed, "unregistration failure")
        let failedRegister = AppStore.resolvedLoginItemOutcome(desired: true, operationFailed: true, status: .notRegistered)
        c.expect(!failedRegister.desired && failedRegister.state == .failed, "failed registration restores disabled intent and reports failure")
        let failedUnregister = AppStore.resolvedLoginItemOutcome(desired: false, operationFailed: true, status: .enabled)
        c.expect(failedUnregister.desired && failedUnregister.state == .enabled, "failed unregister restores enabled intent and state")

        // URL normalization for duplicate prevention.
        c.expect(CalendarURL.normalize("webcal://calendar.google.com/calendar/ical/x/basic.ics") == "https://calendar.google.com/calendar/ical/x/basic.ics", "webcal normalized to https")
        c.expect(CalendarURL.normalize("HTTPS://Example.COM/path/") == "https://example.com/path", "case + trailing slash normalized")
        c.expect(CalendarURL.normalize("https://example.com/path?token=ABC") == "https://example.com/path?token=ABC", "token query preserved")
        c.expect(CalendarURL.normalize("https://a.com/x?token=ABC") != CalendarURL.normalize("https://a.com/x?token=abc"), "token stays case-sensitive (different feeds)")
        c.expect(CalendarURL.normalize("webcal://EXAMPLE.com:8443/a%2Fb?q=x%2Fy&x=1&x=2") == "https://example.com:8443/a%2Fb?q=x%2Fy&x=1&x=2", "webcal normalization preserves port and encoded/repeated query values")
        c.expect(CalendarURL.normalize("https://example.com/a%2Fb") != CalendarURL.normalize("https://example.com/a/b"), "encoded slash stays distinct from path separator")
        c.expect(CalendarURL.normalize("not a url") == nil, "garbage rejected")
        c.expect(CalendarURL.normalize("ftp://example.com/cal.ics") == nil, "non-http scheme rejected")

        let sectionTops: [String: CGFloat] = [
            SettingsSection.calendars.rawValue: -900,
            SettingsSection.native.rawValue: -500,
            SettingsSection.reminder.rawValue: -100,
            SettingsSection.general.rawValue: 170,
            SettingsSection.about.rawValue: 620,
        ]
        c.expect(SettingsView.activeSection(from: sectionTops) == .general, "scroll tracking selects General when it is nearest the reading line")
        c.expect(SettingsView.activeSection(from: sectionTops, viewportHeight: 720, contentBottom: 720) == .about, "scroll tracking selects About at document bottom")

        let windowStart = Date(timeIntervalSince1970: 1_800_000_000)
        let windowEnd = windowStart.addingTimeInterval(3600)
        c.expect(NativeCalendarSource.isWithinFetchWindow(start: windowEnd, end: windowEnd.addingTimeInterval(60), windowStart: windowStart, windowEnd: windowEnd), "native fetch includes a start exactly at window end")
        c.expect(!NativeCalendarSource.isWithinFetchWindow(start: windowEnd.addingTimeInterval(0.001), end: windowEnd.addingTimeInterval(60), windowStart: windowStart, windowEnd: windowEnd), "native fetch excludes starts after window end")

        // Tooltip wrapping: overlong tokens (URLs) get chunked.
        let longToken = "https://example.com/very/long/path/with/a/secret/token/that/keeps/going/on"
        let wrapped = Fmt.wrapped("Join at \(longToken) now", width: 20, maxLines: 4)
        c.expect(wrapped.components(separatedBy: "\n").allSatisfy { $0.count <= 22 }, "long tokens wrapped to width (got \(wrapped))")

        // Per-entry persisted recovery: one bad element must not nuke the rest.
        let stateJSON = """
        {"subscriptions":[{"name":"Good","url":"https://good.example.com/cal.ics","id":"00000000-0000-0000-0000-000000000001"},{"name":"Bad","url":123}],
         "settings":{"leadSeconds":300},
         "nativeCalendars":[{"ekIdentifier":"x","name":"GoodNative","id":"00000000-0000-0000-0000-000000000002"},{"ekIdentifier":42}]}
        """
        let recovered = try? JSONDecoder().decode(Persisted.self, from: Data(stateJSON.utf8))
        c.expect(recovered?.subscriptions.count == 1 && recovered?.subscriptions.first?.name == "Good", "malformed subscription skipped, good one kept")
        c.expect(recovered?.nativeCalendars.count == 1 && recovered?.nativeCalendars.first?.name == "GoodNative", "malformed native calendar skipped, good one kept")
        let allBad = try? JSONDecoder().decode(Persisted.self, from: Data("{\"subscriptions\":\"nope\"}".utf8))
        c.expect(allBad?.subscriptions.isEmpty == true && allBad?.settings == AppSettings(), "fully malformed state falls back to defaults")

        // Contrast-safe color derivation.
        let black = NSColor.black
        let lightened = Palette.readable(black, on: .onBlack)
        c.expect(Palette.luminance(lightened) >= 0.17, "near-black lightened for dark background (luminance \(Palette.luminance(lightened)))")
        let darkened = Palette.readable(NSColor.white, on: .onWhite)
        c.expect(Palette.luminance(darkened) <= 0.83, "near-white darkened for light background (luminance \(Palette.luminance(darkened)))")
        let mid = Palette.nsColor(hex: "#3478F0") // system-blue-ish
        c.expect(Palette.readable(mid, on: .onBlack) === mid.usingColorSpace(.sRGB) ?? mid, "already-readable color unchanged")
        let darkButton = Palette.alertButtonColor(.black)
        c.expect(Palette.luminance(darkButton) >= 0.17, "alert button stays visible on black")
        let lightButton = Palette.alertButtonColor(.white)
        c.expect(Palette.luminance(lightButton) <= 0.31, "alert button keeps white label readable")

        // Permission-request reentrancy: repeated clicks start ONE request.
        var gate = AccessRequestGate()
        c.expect(gate.shouldStart() == true, "first access request starts")
        c.expect(gate.shouldStart() == false, "second click ignored while in flight")
        gate.finish()
        c.expect(gate.shouldStart() == true, "new request possible after completion")
    }

    // MARK: - Fetch merge (refresh correctness)

    static func fetchMergeTests(_ c: inout Checker) {
        func event(_ uid: String, cal: UUID, minutesFromNow: Int) -> MeetingEvent {
            MeetingEvent(uid: uid, title: uid, start: Date().addingTimeInterval(TimeInterval(minutesFromNow) * 60),
                         end: Date().addingTimeInterval(TimeInterval(minutesFromNow + 30) * 60),
                         location: nil, notes: nil, link: nil, calendarID: cal, calendarName: "Cal", colorIndex: 0)
        }
        var subA = CalendarSubscription(name: "A", url: "https://a.example.com/cal.ics", colorIndex: 0)
        let subB = CalendarSubscription(name: "B", url: "https://b.example.com/cal.ics", colorIndex: 1)

        // Cached state: one event per subscription.
        let cachedA = event("a1", cal: subA.id, minutesFromNow: 10)
        let cachedB = event("b1", cal: subB.id, minutesFromNow: 20)
        let current = [cachedA, cachedB]

        // Failed full refresh: errors recorded, cached events preserved for both.
        let failed = AppStore.mergeICS(current: current, results: [
            FetchResult(subscription: subA, events: [], error: "Server returned 503"),
            FetchResult(subscription: subB, events: [], error: "offline"),
        ], live: [subA, subB], previousErrors: [:])
        c.expect(failed.events.map(\.id).sorted() == [cachedA.id, cachedB.id].sorted(), "failed full refresh preserves cached events")
        c.expect(failed.errors[subA.id] == "Server returned 503" && failed.errors[subB.id] == "offline", "failed full refresh records errors")
        c.expect(!failed.allSucceeded, "failed full refresh not allSucceeded")

        // Failed targeted refresh (A only): A keeps cache + error, B untouched —
        // B's own error from its last fetch survives.
        let targeted = AppStore.mergeICS(current: current, results: [
            FetchResult(subscription: subA, events: [], error: "Empty response"),
        ], live: [subA, subB], previousErrors: [subB.id: "old error"])
        c.expect(targeted.events.count == 2, "failed targeted refresh preserves cached events")
        c.expect(targeted.errors[subA.id] == "Empty response", "failed targeted refresh records error")
        c.expect(targeted.errors[subB.id] == "old error", "targeted refresh leaves other subscription's error alone")

        // Successful refresh replaces only the fetched subscription's events.
        let freshA = event("a2", cal: subA.id, minutesFromNow: 5)
        let replaced = AppStore.mergeICS(current: current, results: [
            FetchResult(subscription: subA, events: [freshA], error: nil),
        ], live: [subA, subB], previousErrors: [subA.id: "old"])
        c.expect(replaced.events.filter { $0.calendarID == subA.id }.map(\.uid) == ["a2"], "successful refresh replaces subscription events")
        c.expect(replaced.events.contains { $0.id == cachedB.id }, "other subscription untouched")
        c.expect(replaced.errors[subA.id] == nil, "successful refresh clears error")
        c.expect(replaced.allSucceeded, "successful refresh allSucceeded")

        // Removal mid-flight: result for a deleted subscription is dropped, and its
        // cached events go away too (no resurrection).
        let removed = AppStore.mergeICS(current: current, results: [
            FetchResult(subscription: subA, events: [event("a3", cal: subA.id, minutesFromNow: 1)], error: nil),
        ], live: [subB], previousErrors: [:])
        c.expect(removed.events.map(\.id) == [cachedB.id], "removed subscription's late result dropped with its events")

        // Disabled mid-flight: same as removed.
        var disabledB = subB
        disabledB.isEnabled = false
        let disabled = AppStore.mergeICS(current: current, results: [
            FetchResult(subscription: subB, events: [event("b2", cal: subB.id, minutesFromNow: 1)], error: nil),
        ], live: [subA, disabledB], previousErrors: [subB.id: "stale error"], previousWarnings: [subB.id: "stale warning"])
        c.expect(disabled.events.map(\.id) == [cachedA.id], "disabled subscription's late result dropped with its events")
        c.expect(disabled.errors[subB.id] == nil && disabled.warnings[subB.id] == nil, "disabled subscription diagnostics are pruned")

        // URL edited mid-flight: old-URL result is stale and dropped; cached events kept.
        subA.url = "https://a.example.com/edited.ics"
        let edited = AppStore.mergeICS(current: current, results: [
            FetchResult(subscription: CalendarSubscription(name: "A", url: "https://a.example.com/cal.ics", colorIndex: 0), events: [event("a4", cal: subA.id, minutesFromNow: 1)], error: nil),
        ], live: [subA, subB], previousErrors: [:])
        c.expect(edited.events.contains { $0.id == cachedA.id }, "stale URL result keeps cached events")
        c.expect(!edited.events.contains { $0.uid == "a4" }, "stale URL result not applied")

        // Empty success (no enabled subscriptions fetched) is vacuous success.
        let empty = AppStore.mergeICS(current: [], results: [], live: [subA, subB], previousErrors: [:])
        c.expect(empty.allSucceeded, "no-result refresh is vacuous success")

        // Out-of-order completion via request generations: a targeted resync that
        // started before a full refresh must be dropped when the full refresh has
        // since started for that subscription (older data must not win).
        let subC = CalendarSubscription(name: "C", url: "https://c.example.com/cal.ics", colorIndex: 0)
        let subD = CalendarSubscription(name: "D", url: "https://d.example.com/cal.ics", colorIndex: 1)
        let cachedC = event("c1", cal: subC.id, minutesFromNow: 10)
        var tracker = FetchTracker()
        let targetedID = tracker.begin(subscriptionID: subC.id)
        let fullID = tracker.beginFull(subscriptionIDs: [subC.id, subD.id])
        let lateTargeted = AppStore.mergeICS(current: [cachedC], results: [
            FetchResult(subscription: subC, events: [event("c2", cal: subC.id, minutesFromNow: 5)], error: nil, requestID: targetedID),
        ], live: [subC, subD], previousErrors: [:], latestRequestIDs: tracker.latestPerSubscription)
        c.expect(lateTargeted.events.map(\.id) == [cachedC.id], "out-of-order targeted result (older than full refresh) dropped")
        let newerFull = AppStore.mergeICS(current: [cachedC], results: [
            FetchResult(subscription: subC, events: [event("c3", cal: subC.id, minutesFromNow: 5)], error: nil, requestID: fullID),
        ], live: [subC, subD], previousErrors: [:], latestRequestIDs: tracker.latestPerSubscription)
        c.expect(newerFull.events.map(\.uid) == ["c3"], "current full refresh result applied")

        // And the reverse: a resync that started AFTER the full refresh supersedes
        // the full refresh's result for that subscription.
        let resyncID = tracker.begin(subscriptionID: subC.id)
        let supersededFull = AppStore.mergeICS(current: [cachedC], results: [
            FetchResult(subscription: subC, events: [event("c4", cal: subC.id, minutesFromNow: 5)], error: nil, requestID: fullID),
        ], live: [subC, subD], previousErrors: [subC.id: "new targeted failure"], previousWarnings: [subC.id: "new targeted warning"], latestRequestIDs: tracker.latestPerSubscription)
        c.expect(supersededFull.events.map(\.id) == [cachedC.id], "full refresh result superseded by newer targeted resync")
        c.expect(supersededFull.errors[subC.id] == "new targeted failure" && supersededFull.warnings[subC.id] == "new targeted warning", "superseded full refresh preserves newer targeted diagnostics")
        c.expect(!supersededFull.allSucceeded, "superseded full refresh cannot advance last successful sync")
        let currentResync = AppStore.mergeICS(current: [cachedC], results: [
            FetchResult(subscription: subC, events: [event("c5", cal: subC.id, minutesFromNow: 5)], error: nil, requestID: resyncID),
        ], live: [subC, subD], previousErrors: [:], latestRequestIDs: tracker.latestPerSubscription)
        c.expect(currentResync.events.map(\.uid) == ["c5"], "newer targeted resync applied")
    }

    // MARK: - Commit bookkeeping

    static func bookkeepingTests(_ c: inout Checker) {
        func event(_ uid: String, cal: UUID, minutesFromNow: Int) -> MeetingEvent {
            MeetingEvent(uid: uid, title: uid, start: Date().addingTimeInterval(TimeInterval(minutesFromNow) * 60),
                         end: Date().addingTimeInterval(TimeInterval(minutesFromNow + 30) * 60),
                         location: nil, notes: nil, link: nil, calendarID: cal, calendarName: "Cal", colorIndex: 0)
        }
        let cal = UUID()
        let e1 = event("1", cal: cal, minutesFromNow: 10)
        let e2 = event("2", cal: cal, minutesFromNow: 20)
        let alerted: Set<String> = [e1.id, e2.id]
        let snoozed = [e2.id: Date().addingTimeInterval(60)]

        // First miss (id gone from active but present in previous commit): bookkeeping kept.
        let firstMiss = AppStore.prunedBookkeeping(alerted: alerted, snoozed: snoozed, activeIDs: [e1.id], previousIDs: [e1.id, e2.id])
        c.expect(firstMiss.alerted == alerted && firstMiss.snoozed == snoozed, "single miss keeps bookkeeping")

        // Second identical missing snapshot: pruned.
        let secondMiss = AppStore.prunedBookkeeping(alerted: firstMiss.alerted, snoozed: firstMiss.snoozed, activeIDs: [e1.id], previousIDs: [e1.id])
        c.expect(secondMiss.alerted == [e1.id] && secondMiss.snoozed.isEmpty, "two consecutive misses prune bookkeeping")

        // Never prunes ids that are still active.
        let stable = AppStore.prunedBookkeeping(alerted: alerted, snoozed: snoozed, activeIDs: [e1.id, e2.id], previousIDs: [e1.id, e2.id])
        c.expect(stable.alerted == alerted && stable.snoozed == snoozed, "active ids keep bookkeeping")

        // Normalization: dedupe by id, stable ordering for equal starts.
        let tie1 = event("tie-b", cal: cal, minutesFromNow: 10)
        let tie2 = MeetingEvent(uid: "tie-a", title: "tie-a", start: tie1.start, end: tie1.end, location: nil, notes: nil, link: nil, calendarID: cal, calendarName: "Cal", colorIndex: 0)
        let normalized = AppStore.normalizedEvents([tie1, e2, tie1, tie2])
        c.expect(normalized.count == 3, "duplicate ids deduped")
        c.expect(normalized.first?.id == tie2.id, "equal starts ordered by title tie-breaker")
    }

    // MARK: - Title filters (muted meetings)

    static func titleFilterTests(_ c: inout Checker) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // Exact matching: whole-title, case-insensitive, whitespace-trimmed.
        let exact = TitleFilterRule(pattern: "  Weekly Standup \n", mode: .exact)
        c.expect(exact.matches(title: "Weekly Standup"), "exact rule matches same title (trimmed)")
        c.expect(exact.matches(title: "weekly standup"), "exact rule is case-insensitive")
        c.expect(!exact.matches(title: "Weekly Standup — extra"), "exact rule requires the whole title")
        c.expect(!exact.matches(title: "Standup"), "exact rule rejects different title")
        c.expect(!exact.matches(title: ""), "exact rule never matches an empty title")
        c.expect(exact.isValid, "exact rule with content is valid")

        // Regex: search semantics, anchors, inline case flag, literal escapes.
        c.expect(TitleFilterRule(pattern: "^1:1 with .+$", mode: .regex).matches(title: "1:1 with Alice"), "regex searches with anchors")
        c.expect(!TitleFilterRule(pattern: "^1:1", mode: .regex).matches(title: "Prep 1:1"), "anchored regex rejects other positions")
        c.expect(TitleFilterRule(pattern: "(?i)standup", mode: .regex).matches(title: "WEEKLY STANDUP"), "regex honors inline (?i)")
        c.expect(TitleFilterRule(pattern: "a\\.b", mode: .regex).matches(title: "xa.bz"), "regex escapes literal dots")
        c.expect(!TitleFilterRule(pattern: "(?i)standup", mode: .regex).matches(title: "Retro"), "regex rejects non-matching title")

        // Invalid / empty / over-length patterns are inert, never fatal.
        let invalid = TitleFilterRule(pattern: "([unclosed", mode: .regex)
        c.expect(!invalid.isValid && !invalid.matches(title: "anything"), "invalid regex is flagged and inert")
        let blank = TitleFilterRule(pattern: "   ", mode: .exact)
        c.expect(!blank.isValid && !blank.matches(title: "x"), "empty pattern is inert")
        let overlength = TitleFilterRule(pattern: String(repeating: "a", count: TitleFilterRule.maxRegexPatternLength + 1), mode: .regex)
        c.expect(!overlength.isValid && !overlength.matches(title: String(repeating: "a", count: 600)), "over-length regex pattern is invalid and inert")
        // Exact rules carry no length cap: equality is cheap, and truncating a
        // title would silently break "whole title" semantics.
        let longTitle = String(repeating: "t", count: 600)
        c.expect(TitleFilterRule(pattern: longTitle, mode: .exact).matches(title: longTitle), "very long exact rule still matches")

        // Rule lists: any-match, ordered selection, prepared-matcher equivalence.
        let rules = [
            TitleFilterRule(pattern: "Standup", mode: .exact),
            TitleFilterRule(pattern: "^Focus.*Block$", mode: .regex),
            TitleFilterRule(pattern: "Standup", mode: .regex), // second Standup matcher (regex flavor)
        ]
        c.expect(TitleFilterRule.matches(title: "STANDUP", rules: rules), "rule list matches via exact rule (case-insensitive)")
        c.expect(TitleFilterRule.matches(title: "Focus Deep Block", rules: rules), "rule list matches via regex")
        c.expect(!TitleFilterRule.matches(title: "Retro", rules: rules), "rule list rejects non-matching title")
        c.expect(TitleFilterRule.matchingRules(title: "Standup", rules: rules).map(\.pattern) == ["Standup", "Standup"], "matchingRules returns the matching subset in list order")
        c.expect(TitleFilterRule.matchingRules(title: "Retro", rules: rules).isEmpty, "matchingRules empty when nothing matches")
        let matcher = TitleFilterMatcher(rules: rules)
        c.expect(matcher.matches(title: "STANDUP") && matcher.matches(title: "Focus Deep Block") && !matcher.matches(title: "Retro"), "prepared matcher equals per-rule matching")

        // Toggle helpers: add (deduped), selective remove, normalization caps.
        let added = TitleFilterRule.addingExact(title: "  Retro \n", rules: rules)
        c.expect(added.count == rules.count + 1 && added.last?.pattern == "Retro" && added.last?.mode == .exact, "addingExact appends a trimmed exact rule")
        c.expect(TitleFilterRule.addingExact(title: "standup", rules: rules).count == rules.count, "addingExact dedupes case-insensitive duplicates")
        c.expect(TitleFilterRule.addingExact(title: "  ", rules: rules).count == rules.count, "addingExact ignores empty titles")
        c.expect(TitleFilterRule.removing(ids: [rules[0].id], from: rules).map(\.pattern) == ["^Focus.*Block$", "Standup"], "removing drops exactly the selected ids")
        let many = (0..<60).map { TitleFilterRule(pattern: "rule\($0)", mode: .exact) }
        c.expect(TitleFilterRule.normalized(many).count == TitleFilterRule.maxRulesPerCalendar, "normalization caps the rule count")
        let messy = [
            TitleFilterRule(pattern: "  x  ", mode: .exact),
            TitleFilterRule(pattern: "X", mode: .exact),
            TitleFilterRule(pattern: "", mode: .exact),
            TitleFilterRule(pattern: "y", mode: .regex),
            TitleFilterRule(pattern: "y", mode: .regex),
            invalid, // invalid regex is KEPT (editable persisted state), just inert
        ]
        c.expect(TitleFilterRule.normalized(messy).map(\.pattern) == ["x", "y", "([unclosed"], "normalization trims, drops empties, dedupes, keeps invalid regexes")

        // Decoding: defaults for missing keys, per-entry failure containment,
        // old JSON without the key, cap enforcement, invalid-regex persistence.
        func decodeSubscription(_ json: String) -> CalendarSubscription? {
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(CalendarSubscription.self, from: data)
        }
        c.expect(decodeSubscription(#"{"name":"Work","url":"https://x.example/cal.ics"}"#)?.titleFilters.isEmpty ?? false, "subscriptions decode without titleFilters key (backward compat)")
        let malformed = decodeSubscription(#"{"name":"Work","url":"https://x.example/cal.ics","titleFilters":[{"pattern":"OK"},{"id":123,"pattern":"bad"}]}"#)
        c.expect(malformed?.titleFilters.map(\.pattern) == ["OK"], "one malformed rule entry never fails the calendar record")
        let defaults = decodeSubscription(#"{"name":"Work","url":"https://x.example/cal.ics","titleFilters":[{"pattern":"Retro"}]}"#)
        c.expect(defaults?.titleFilters.first?.mode == .exact, "missing mode decodes to exact (the default)")
        let missingFieldsData = #"{"mode":"exact"}"#.data(using: .utf8)!
        let missingFieldsA = try? JSONDecoder().decode(TitleFilterRule.self, from: missingFieldsData)
        let missingFieldsB = try? JSONDecoder().decode(TitleFilterRule.self, from: missingFieldsData)
        c.expect(missingFieldsA?.pattern == "" && missingFieldsA?.id != missingFieldsB?.id, "missing pattern is inert and missing ids receive fresh UUIDs")
        let overCapJSON = "[" + (0..<60).map { #"{"pattern":"r\#($0)"}"# }.joined(separator: ",") + "]"
        c.expect(decodeSubscription(#"{"name":"Work","url":"https://x.example/cal.ics","titleFilters":\#(overCapJSON)}"#)?.titleFilters.count == TitleFilterRule.maxRulesPerCalendar, "decode truncates over-cap rule lists")
        let nativeData = #"{"ekIdentifier":"EK-1","name":"Home","titleFilters":[{"pattern":"G(y","mode":"regex"},{"pattern":"Quiet hours"}]}"#.data(using: .utf8)!
        let native = try? JSONDecoder().decode(NativeCalendar.self, from: nativeData)
        c.expect(native?.titleFilters.count == 2 && native?.titleFilters.first?.isValid == false, "native calendar decodes rules; invalid regex stays inert but persisted")
        let roundTrip = try? JSONDecoder().decode([TitleFilterRule].self, from: JSONEncoder().encode(rules))
        c.expect(roundTrip == rules, "title filter rules round-trip through codable")

        // mergeICS computes muted from LIVE rules — a fetch that started before
        // a rule edit lands with the new flags applied (never the stale snapshot).
        var liveSub = CalendarSubscription(name: "M", url: "https://m.example/cal.ics", colorIndex: 0)
        func fetchEvent(_ uid: String, title: String) -> MeetingEvent {
            MeetingEvent(uid: uid, title: title, start: now.addingTimeInterval(600), end: now.addingTimeInterval(2400),
                         location: nil, notes: nil, link: nil, calendarID: liveSub.id, calendarName: "Cal", colorIndex: 0)
        }
        let fetchSnapshot = liveSub // rules are added AFTER the fetch started
        liveSub.titleFilters = [TitleFilterRule(pattern: "Standup", mode: .exact)]
        let subscriptionFlags = TitleFilterMatcher.applying(
            to: [fetchEvent("flag-s", title: "Standup"), fetchEvent("flag-r", title: "Retro")],
            subscriptions: [liveSub])
        c.expect(subscriptionFlags.map(\.isMuted) == [true, false], "subscription reconcile helper applies and clears derived muted flags")
        var nativeForFlags = NativeCalendar(ekIdentifier: "EK-FLAGS", name: "Native")
        nativeForFlags.titleFilters = [TitleFilterRule(pattern: "Retro", mode: .exact)]
        let staleMutedNative = MeetingEvent(uid: "native-s", title: "Standup", start: now.addingTimeInterval(600), end: now.addingTimeInterval(2400),
                                            location: nil, notes: nil, link: nil, calendarID: nativeForFlags.id, calendarName: "Native", colorIndex: 0, isMuted: true)
        let nativeRetro = MeetingEvent(uid: "native-r", title: "Retro", start: now.addingTimeInterval(900), end: now.addingTimeInterval(2700),
                                       location: nil, notes: nil, link: nil, calendarID: nativeForFlags.id, calendarName: "Native", colorIndex: 0)
        let nativeFlags = TitleFilterMatcher.applying(to: [staleMutedNative, nativeRetro], nativeCalendars: [nativeForFlags])
        c.expect(nativeFlags.map(\.isMuted) == [false, true], "native reconcile helper clears stale flags and applies current rules")
        let fetched = AppStore.mergeICS(current: [], results: [
            FetchResult(subscription: fetchSnapshot, events: [fetchEvent("s1", title: "Standup"), fetchEvent("s2", title: "Retro")], error: nil),
        ], live: [liveSub], previousErrors: [:])
        c.expect(fetched.events.filter(\.isMuted).map(\.uid) == ["s1"], "mergeICS flags muted events from live rules (not the fetch snapshot)")
        // Cached events of untouched subscriptions get refreshed flags too.
        var otherSub = CalendarSubscription(name: "N", url: "https://n.example/cal.ics", colorIndex: 1)
        otherSub.titleFilters = [TitleFilterRule(pattern: "Retro", mode: .exact)]
        let retroEvent = MeetingEvent(uid: "s2", title: "Retro", start: now.addingTimeInterval(600), end: now.addingTimeInterval(2400),
                                      location: nil, notes: nil, link: nil, calendarID: otherSub.id, calendarName: "Cal", colorIndex: 0)
        let cached = AppStore.mergeICS(current: [retroEvent], results: [], live: [otherSub], previousErrors: [:])
        c.expect(cached.events.filter(\.isMuted).map(\.uid) == ["s2"], "mergeICS refreshes muted flags of kept cached events")

        // dueForAlert never fires muted events — the pure seam tick() shares.
        var mutedDue = fetchEvent("m1", title: "Standup")
        mutedDue.isMuted = true
        c.expect(AppStore.dueForAlert(events: [mutedDue], alerted: [], snoozed: [:], leadSeconds: 300, now: now).isEmpty, "muted event inside its window never fires")
        c.expect(AppStore.dueForAlert(events: [mutedDue], alerted: [mutedDue.id], snoozed: [mutedDue.id: now.addingTimeInterval(-5)], leadSeconds: 300, now: now).isEmpty, "muted event with expired snooze still never fires")

        // Unmute ratchet: silences muted→unmuted transitions whose lead window
        // already started (rule edits, title changes on refresh, native rebuilds
        // — anything that keeps the id), and clears snoozes so the silence holds.
        let ratchetCal = UUID()
        func ratchetEvent(_ uid: String, muted: Bool, startIn: TimeInterval) -> MeetingEvent {
            var event = MeetingEvent(uid: uid, title: uid, start: now.addingTimeInterval(startIn), end: now.addingTimeInterval(startIn + 1800),
                                     location: nil, notes: nil, link: nil, calendarID: ratchetCal, calendarName: "Cal", colorIndex: 0)
            event.isMuted = muted
            return event
        }
        let mutedRunning = ratchetEvent("r", muted: true, startIn: -60)
        let unmutedRunning = ratchetEvent("r", muted: false, startIn: -60)
        c.expect(mutedRunning.id == unmutedRunning.id, "same uid/calendar/start share an id (title-edit refresh keeps id)")
        let ratcheted = AppStore.ratchetSilence(previous: [mutedRunning], current: [unmutedRunning], alerted: [], snoozed: [unmutedRunning.id: now.addingTimeInterval(-5)], leadSeconds: 300, now: now)
        c.expect(ratcheted.alerted == [unmutedRunning.id] && ratcheted.snoozed[unmutedRunning.id] == nil, "muted→unmuted inside the window is silenced and its snooze cleared")
        let unmutedFuture = ratchetEvent("f", muted: false, startIn: 3600)
        let futureOutcome = AppStore.ratchetSilence(previous: [ratchetEvent("f", muted: true, startIn: 3600)], current: [unmutedFuture], alerted: [], snoozed: [:], leadSeconds: 300, now: now)
        c.expect(!futureOutcome.alerted.contains(unmutedFuture.id), "unmute before the lead window alerts normally")
        let endedOutcome = AppStore.ratchetSilence(previous: [ratchetEvent("e", muted: true, startIn: -3600)], current: [ratchetEvent("e", muted: false, startIn: -3600)], alerted: [], snoozed: [:], leadSeconds: 300, now: now)
        c.expect(endedOutcome.alerted.isEmpty, "ended event is not ratcheted")
        let freshOutcome = AppStore.ratchetSilence(previous: [], current: [unmutedRunning], alerted: [], snoozed: [:], leadSeconds: 300, now: now)
        c.expect(freshOutcome.alerted.isEmpty, "brand-new unmuted events keep late-delivery behavior")
        let stableOutcome = AppStore.ratchetSilence(previous: [unmutedRunning], current: [unmutedRunning], alerted: [unmutedRunning.id], snoozed: [:], leadSeconds: 300, now: now)
        c.expect(stableOutcome.alerted == [unmutedRunning.id] && stableOutcome.snoozed.isEmpty, "repeated commits leave the ratchet stable")

        let mutedNearest = ratchetEvent("nearest", muted: true, startIn: -30)
        let future = ratchetEvent("future", muted: false, startIn: 600)
        c.expect(AppStore.nextEvent(events: [mutedNearest, future], lateMinutes: 0, now: now)?.id == future.id, "nextEvent skips a muted running meeting")
        let running = ratchetEvent("running", muted: false, startIn: -60)
        c.expect(AppStore.nextEvent(events: [future, running], lateMinutes: 0, now: now)?.id == running.id, "nextEvent preserves running-before-future priority")
        c.expect(AppStore.nextEvent(events: [mutedNearest], lateMinutes: 0, now: now)?.id == nil, "nextEvent is empty when every visible meeting is muted")

        // The full snooze sequence: alert → snooze → mute → snooze expires →
        // unmute mid-window → still no reminder.
        var sequence = ratchetEvent("seq", muted: false, startIn: -120)
        let sequenceMuted = ratchetEvent("seq", muted: true, startIn: -120)
        var step = AppStore.ratchetSilence(previous: [sequence], current: [sequenceMuted], alerted: [sequence.id], snoozed: [sequence.id: now.addingTimeInterval(-5)], leadSeconds: 300, now: now)
        step = AppStore.ratchetSilence(previous: [sequenceMuted], current: [sequence], alerted: step.alerted, snoozed: step.snoozed, leadSeconds: 300, now: now)
        sequence.isMuted = false
        c.expect(AppStore.dueForAlert(events: [sequence], alerted: step.alerted, snoozed: step.snoozed, leadSeconds: 300, now: now).isEmpty, "snoozed→muted→unmuted mid-window never re-fires")

        // An open alert panel drops cards whose events became muted.
        let shownMuted = ratchetEvent("shown", muted: false, startIn: 120)
        let nowMuted = ratchetEvent("shown", muted: true, startIn: 120)
        let otherCard = ratchetEvent("other", muted: false, startIn: 120)
        c.expect(AlertController.reconciledShownEvents(shown: [shownMuted, otherCard], current: [nowMuted, otherCard]).map(\.uid) == ["other"], "reconciliation drops muted cards, keeps the rest")
    }

    // MARK: - Auto-updater

    static func updateTests(_ c: inout Checker) {
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
            cal.date(from: DateComponents(timeZone: utc, year: year, month: month, day: day, hour: hour))!
        }
        let now = date(2026, 8, 30)

        // -- Release JSON parsing ------------------------------------------
        func releaseJSON(tag: String, assets: [(name: String, url: String, size: Int)], published: String? = "2026-08-29T12:00:00Z", body: String = "- Fixed things\n\nFull changelog: https://github.com/BoThomas/now/compare/v1.4.0...v1.5.0") -> String {
            let assetList = assets.map { asset in
                "{\"name\":\"\(asset.name)\",\"browser_download_url\":\"\(asset.url)\",\"size\":\(asset.size)}"
            }.joined(separator: ",")
            var json = "{\"tag_name\":\"\(tag)\",\"assets\":[\(assetList)]"
            if let published { json += ",\"published_at\":\"\(published)\"" }
            json += ",\"body\":\(dataEscaped(body))}"
            return json
        }
        func dataEscaped(_ text: String) -> String {
            String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
        }
        let good = UpdateLogic.parseLatestRelease(releaseJSON(tag: "v1.5.0", assets: [("now-v1.5.0.zip", "https://github.com/BoThomas/now/releases/download/v1.5.0/now-v1.5.0.zip", 1_234_567)]).data(using: .utf8)!)
        c.expect(good?.version == "1.5.0", "release parsed to version")
        c.expect(good?.assetSize == 1_234_567, "release asset size parsed")
        c.expect(good?.zipURL.absoluteString == "https://github.com/BoThomas/now/releases/download/v1.5.0/now-v1.5.0.zip", "release asset url parsed")
        c.expect(good.map { abs($0.publishedAt.timeIntervalSince(date(2026, 8, 29, hour: 12))) < 1 } == true, "published_at parsed")
        c.expect(UpdateLogic.parseLatestRelease(releaseJSON(tag: "v1.5.0", assets: [("wrong-name.zip", "https://x/now.zip", 10)]).data(using: .utf8)!) == nil, "wrong asset name rejected")
        c.expect(UpdateLogic.parseLatestRelease(releaseJSON(tag: "v1.5.0", assets: []).data(using: .utf8)!) == nil, "missing assets rejected")
        c.expect(UpdateLogic.parseLatestRelease(releaseJSON(tag: "1.5.0", assets: [("now-v1.5.0.zip", "https://x/now.zip", 10)]).data(using: .utf8)!) == nil, "tag without v prefix rejected")
        c.expect(UpdateLogic.parseLatestRelease(releaseJSON(tag: "v1.5", assets: [("now-v1.5.zip", "https://x/now.zip", 10)]).data(using: .utf8)!) == nil, "2-component tag rejected")
        c.expect(UpdateLogic.parseLatestRelease(releaseJSON(tag: "v1.5.0-beta.1", assets: [("now-v1.5.0-beta.1.zip", "https://x/now.zip", 10)]).data(using: .utf8)!) == nil, "non-numeric tag suffix rejected")
        c.expect(UpdateLogic.parseLatestRelease(Data("{\"garbage\":true}".utf8)) == nil, "malformed JSON rejected")
        // Missing published_at counts as just-released (age gate keeps blocking).
        let fallbackDate = date(2026, 8, 28, hour: 9)
        let noDate = UpdateLogic.parseLatestRelease(releaseJSON(tag: "v1.5.0", assets: [("now-v1.5.0.zip", "https://x/now.zip", 10)], published: nil).data(using: .utf8)!, now: fallbackDate)
        c.expect(noDate?.publishedAt == fallbackDate, "missing published_at → injected current time")

        // -- Version comparison --------------------------------------------
        c.expect(UpdateLogic.isVersion("1.5.1", newerThan: "1.5.0"), "patch newer")
        c.expect(!UpdateLogic.isVersion("1.5.0", newerThan: "1.5.0"), "equal is not newer")
        c.expect(!UpdateLogic.isVersion("1.4.9", newerThan: "1.5.0"), "older is not newer")
        c.expect(UpdateLogic.isVersion("1.10.0", newerThan: "1.9.9"), "numeric compare, not string (1.10 > 1.9)")
        c.expect(UpdateLogic.isVersion("2.0.0", newerThan: "1.99.99"), "major bump newer")
        c.expect(!UpdateLogic.isVersion("1.5", newerThan: "1.4.0"), "2-component candidate rejected")
        c.expect(!UpdateLogic.isVersion("2.-1.0", newerThan: "1.4.0"), "negative component rejected")
        c.expect(!UpdateLogic.isVersion("02.0.0", newerThan: "1.4.0"), "leading-zero component rejected")
        c.expect(UpdateLogic.version(fromTag: "v2.3.4") == "2.3.4", "tag parse")
        c.expect(UpdateLogic.version(fromTag: "v+2.3.4") == nil, "signed version component rejected")
        c.expect(UpdateLogic.version(fromTag: "v２.3.4") == nil, "non-ASCII version component rejected")

        c.expect(!UpdateFetch.isSuccessfulStatus(nil), "non-HTTP update status rejected")
        c.expect(!UpdateFetch.isSuccessfulStatus(199), "1xx update status rejected")
        c.expect(UpdateFetch.isSuccessfulStatus(200) && UpdateFetch.isSuccessfulStatus(299), "2xx update status accepted")
        c.expect(!UpdateFetch.isSuccessfulStatus(300) && !UpdateFetch.isSuccessfulStatus(500), "non-2xx update status rejected")
        c.expect(UpdateTransport.session.delegate === UpdateTransport.delegate, "redirect-gated updater session is wired")
        c.expect(AppStore.session.delegate === AppStore.transportDelegate, "redirect-gated calendar session is wired")
        let secureFeed = URL(string: "https://calendar.example.com/private.ics")!
        let secureCDN = URL(string: "https://cdn.example.com/private.ics")!
        let insecureCDN = URL(string: "http://cdn.example.com/private.ics")!
        let consentedHTTP = URL(string: "http://calendar.example.com/private.ics")!
        c.expect(CalendarTransportDelegate.allowsRedirect(from: secureFeed, to: secureCDN), "calendar HTTPS redirect stays allowed")
        c.expect(!CalendarTransportDelegate.allowsRedirect(from: secureFeed, to: insecureCDN), "calendar HTTPS-to-HTTP redirect blocked")
        c.expect(CalendarTransportDelegate.allowsRedirect(from: consentedHTTP, to: secureCDN), "consented HTTP feed may upgrade to HTTPS")
        c.expect(CalendarTransportDelegate.allowsRedirect(from: consentedHTTP, to: insecureCDN), "consented HTTP feed may redirect within HTTP")
        c.expect(UpdateFetch.allows(URL(string: "https://api.github.com/x")!, apiBaseOverride: nil), "production HTTPS transport accepted")
        c.expect(UpdateFetch.allows(URL(string: "https://objects.githubusercontent.com/x")!, apiBaseOverride: nil), "arbitrary HTTPS CDN accepted")
        c.expect(!UpdateFetch.allows(URL(string: "http://127.0.0.1:8000/x")!, apiBaseOverride: nil), "loopback HTTP rejected without explicit override")
        c.expect(UpdateFetch.allows(URL(string: "http://127.0.0.1:8000/x")!, apiBaseOverride: "http://localhost:9000/api"), "loopback HTTP accepted with explicit loopback override")
        c.expect(!UpdateFetch.allows(URL(string: "http://example.com/x")!, apiBaseOverride: "http://127.0.0.1:8000/api"), "loopback override cannot enable remote HTTP")

        var tracker = StagingTracker()
        let generationA = tracker.begin(version: "1.5.0")
        c.expect(tracker.accepts(generation: generationA, version: "1.5.0", availableVersion: "1.5.0"), "current staging generation accepted")
        let generationB = tracker.begin(version: "1.6.0")
        c.expect(!tracker.accepts(generation: generationA, version: "1.5.0", availableVersion: "1.6.0"), "superseded staging generation rejected")
        c.expect(tracker.accepts(generation: generationB, version: "1.6.0", availableVersion: "1.6.0"), "replacement staging generation accepted")
        tracker.clear()
        c.expect(!tracker.accepts(generation: generationB, version: "1.6.0", availableVersion: "1.6.0"), "cleared staging generation rejected")

        var failedInstall = UpdateState()
        failedInstall.lastNotifiedVersion = "1.4.0"
        failedInstall.pendingInstallVersion = "1.5.0"
        let afterFailure = UpdateLogic.stateAfterInstallFailure(failedInstall)
        c.expect(afterFailure.pendingInstallVersion == nil && afterFailure.lastNotifiedVersion == "1.5.0", "failed install marks pending version notified")
        var noPending = UpdateState()
        noPending.lastNotifiedVersion = "1.3.0"
        c.expect(UpdateLogic.stateAfterInstallFailure(noPending).lastNotifiedVersion == "1.3.0", "failed install without pending version preserves notification")

        c.expect(UpdateLogic.justInstalledVersion(pending: "1.5.0", currentVersion: "1.5.0") == "1.5.0", "relaunch as pending version counts as installed")
        c.expect(UpdateLogic.justInstalledVersion(pending: "1.5.0", currentVersion: "1.4.0") == nil, "old version relaunch (failed install) is not a success")
        c.expect(UpdateLogic.justInstalledVersion(pending: nil, currentVersion: "1.5.0") == nil, "no pending install is not a success")
        var installedState = UpdateState()
        installedState.pendingInstallVersion = "1.5.0"
        installedState.lastNotifiedVersion = "1.5.0"
        let afterInstall = UpdateLogic.stateAfterSuccessfulInstall(installedState)
        c.expect(afterInstall.pendingInstallVersion == nil, "successful install clears pending marker")
        c.expect(afterInstall.lastNotifiedVersion == "1.5.0", "successful install leaves notification memory untouched")
        // The helper's success relaunch must strip a stale NOW_UPDATE_ERROR
        // (inherited from an earlier failed install through spawnHelper's
        // environment pass-through) — otherwise a successful retry would be
        // processed as another failure at launch. update-smoke.sh case 13
        // exercises this end to end.
        c.expect(UpdateInstaller.helperScript.contains("env -u NOW_SMOKE_FAILURE_REPORT -u NOW_UPDATE_ERROR"), "success relaunch strips a stale NOW_UPDATE_ERROR from the child environment")

        // Ack contract (`NowApp.acknowledgeUpdatedStartup`): a helper-launched
        // instance that CANNOT acknowledge must report failure — AppDelegate
        // then never calls `startupHealthAcknowledged()`, so the pending
        // marker survives (for the rolled-back app's bookkeeping) and no
        // success window is requested. Only a fully ABSENT contract (both
        // variables unset — an ordinary launch) reports success; anything
        // less fails closed.
        let ackEnvKeys = ["NOW_SMOKE_HELPER_FAULT", "NOW_HEALTH_TOKEN", "NOW_HEALTH_ACK"]
        func resetAckEnv() { for key in ackEnvKeys { unsetenv(key) } }
        resetAckEnv()
        c.expect(NowApp.acknowledgeUpdatedStartup(), "ordinary launch (no helper contract) acknowledges as no-op success")
        setenv("NOW_SMOKE_HELPER_FAULT", "health", 1)
        c.expect(!NowApp.acknowledgeUpdatedStartup(), "injected health fault is an acknowledgement failure")
        unsetenv("NOW_SMOKE_HELPER_FAULT")
        setenv("NOW_HEALTH_TOKEN", "selftest-token", 1)
        c.expect(!NowApp.acknowledgeUpdatedStartup(), "token present but ack path absent is an acknowledgement failure")
        resetAckEnv()
        setenv("NOW_HEALTH_ACK", "/tmp/now-selftest-ack-unused", 1)
        c.expect(!NowApp.acknowledgeUpdatedStartup(), "ack path present but token absent is an acknowledgement failure")
        setenv("NOW_HEALTH_TOKEN", "", 1)
        c.expect(!NowApp.acknowledgeUpdatedStartup(), "empty token is an acknowledgement failure")
        resetAckEnv()
        setenv("NOW_HEALTH_TOKEN", "selftest-token", 1)
        setenv("NOW_HEALTH_ACK", "", 1)
        c.expect(!NowApp.acknowledgeUpdatedStartup(), "empty ack path is an acknowledgement failure")
        setenv("NOW_HEALTH_ACK", "/nonexistent-now-selftest-dir/health-ack", 1)
        c.expect(!NowApp.acknowledgeUpdatedStartup(), "unwritable acknowledgement file is a failure")
        let ackPath = FileManager.default.temporaryDirectory.appendingPathComponent("now-selftest-ack-\(UUID().uuidString)").path
        setenv("NOW_HEALTH_ACK", ackPath, 1)
        c.expect(NowApp.acknowledgeUpdatedStartup(), "writable acknowledgement file succeeds")
        c.expect((try? String(contentsOfFile: ackPath, encoding: .utf8)) == "\(getpid()):selftest-token", "acknowledgement file contains pid:token")
        resetAckEnv()
        try? FileManager.default.removeItem(atPath: ackPath)
        let requestedOnly = UpdateLogic.stateAfterShowingUpdate(noPending, version: nil)
        c.expect(requestedOnly.lastNotifiedVersion == "1.3.0", "deferred update request does not record notification")
        let actuallyShown = UpdateLogic.stateAfterShowingUpdate(noPending, version: "1.5.0")
        c.expect(actuallyShown.lastNotifiedVersion == "1.5.0", "visible update records notification")
        c.expect(!UpdateLogic.shouldStageUpdate(version: "1.3.0", userInitiated: false, state: noPending), "shown update does not restage automatically")
        c.expect(UpdateLogic.shouldStageUpdate(version: "1.3.0", userInitiated: true, state: noPending), "explicit action restages shown update")
        c.expect(UpdateLogic.shouldStageUpdate(version: "1.5.0", userInitiated: false, state: noPending), "new update stages on first discovery")

        let monitorRoot = FileManager.default.temporaryDirectory.appendingPathComponent("now-process-monitor-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: monitorRoot, withIntermediateDirectories: true)
        let shortLimits = StagingLimits(archiveBytes: 100, extractedBytes: 100, extractionSeconds: 0.05, pollSeconds: 0.01, extractedEntries: 10)
        c.expect(UpdateStaging.runMonitoredProcess("/bin/sleep", ["1"], monitoredDirectory: monitorRoot, limits: shortLimits) == .timedOut, "extraction process timeout enforced")
        try? Data(repeating: 0, count: 101).write(to: monitorRoot.appendingPathComponent("large"))
        var sizeLimits = shortLimits
        sizeLimits.extractionSeconds = 1
        c.expect(UpdateStaging.runMonitoredProcess("/bin/sleep", ["1"], monitoredDirectory: monitorRoot, limits: sizeLimits) == .sizeLimit, "extraction disk budget enforced")
        try? FileManager.default.removeItem(at: monitorRoot)

        // -- Decide ---------------------------------------------------------
        func manifest(version: String, publishedOffsetHours: Double, size: Int = 100) -> UpdateManifest {
            UpdateManifest(version: version, zipURL: URL(string: "https://example.com/now-v\(version).zip")!, assetSize: size, publishedAt: now.addingTimeInterval(-publishedOffsetHours * 3600), notes: "notes")
        }
        let old = manifest(version: "1.4.0", publishedOffsetHours: 100)
        let young = manifest(version: "1.5.0", publishedOffsetHours: 2)
        let mature = manifest(version: "1.5.0", publishedOffsetHours: 48)
        c.expect(UpdateLogic.decide(manifest: old, currentVersion: "1.5.0", skipped: nil, now: now, minAge: 0) == .upToDate, "older release → up to date")
        c.expect(UpdateLogic.decide(manifest: mature, currentVersion: "1.5.0", skipped: nil, now: now, minAge: 0) == .upToDate, "equal version → up to date")
        if case .available = UpdateLogic.decide(manifest: mature, currentVersion: "1.4.0", skipped: nil, now: now, minAge: 0) {} else {
            c.expect(false, "mature newer release → available")
        }
        c.expect(UpdateLogic.decide(manifest: young, currentVersion: "1.4.0", skipped: nil, now: now, minAge: 0) != .upToDate, "young release offered to manual checks")
        c.expect(UpdateLogic.decide(manifest: young, currentVersion: "1.4.0", skipped: nil, now: now, minAge: 24 * 3600) == .upToDate, "young release age-gated for automatic checks")
        if case .skippedVersion("1.5.0") = UpdateLogic.decide(manifest: mature, currentVersion: "1.4.0", skipped: "1.5.0", now: now, minAge: 0) {} else {
            c.expect(false, "skipped version suppressed")
        }
        c.expect(UpdateLogic.decide(manifest: nil, currentVersion: "1.4.0", skipped: nil, now: now, minAge: 0) == .error("no usable release"), "nil manifest → error")

        // -- Throttle (shouldAutoCheck) ------------------------------------
        c.expect(UpdateLogic.shouldAutoCheck(state: UpdateState(), now: now, calendar: cal), "fresh state checks")
        var state = UpdateState()
        state.lastSuccessCheckDate = now.addingTimeInterval(-2 * 3600)
        c.expect(!UpdateLogic.shouldAutoCheck(state: state, now: now, calendar: cal), "recent success silenced for 24 h")
        state.lastSuccessCheckDate = now.addingTimeInterval(-25 * 3600)
        c.expect(UpdateLogic.shouldAutoCheck(state: state, now: now, calendar: cal), "25 h old success checks")
        state.lastAttemptDate = now.addingTimeInterval(-30 * 60)
        c.expect(!UpdateLogic.shouldAutoCheck(state: state, now: now, calendar: cal), "failure retries no sooner than 1 h")
        state.lastAttemptDate = now.addingTimeInterval(-2 * 3600)
        c.expect(UpdateLogic.shouldAutoCheck(state: state, now: now, calendar: cal), "failure 2 h ago retries")
        state.attemptsDayStamp = UpdateLogic.dayStamp(now, calendar: cal)
        state.attemptsToday = 3
        state.lastSuccessCheckDate = now.addingTimeInterval(-25 * 3600)
        state.lastAttemptDate = now.addingTimeInterval(-2 * 3600)
        c.expect(!UpdateLogic.shouldAutoCheck(state: state, now: now, calendar: cal), "max 3 attempts per day")
        c.expect(UpdateLogic.shouldAutoCheck(state: state, now: now.addingTimeInterval(86400), calendar: cal), "attempt counter resets next day")
        c.expect(UpdateLogic.dayStamp(date(2026, 8, 30), calendar: cal) == "2026-08-30", "day stamp format")

        // -- Escalation (shouldEscalate) ------------------------------------
        var escalate = UpdateState()
        c.expect(!UpdateLogic.shouldEscalate(availableVersion: "1.5.0", state: escalate, now: now), "never-seen version does not escalate")
        escalate.firstSeenUpdateVersion = "1.5.0"
        escalate.firstSeenUpdateDate = now.addingTimeInterval(-2 * 86400)
        c.expect(!UpdateLogic.shouldEscalate(availableVersion: "1.5.0", state: escalate, now: now), "2 days uninstalled stays quiet")
        escalate.firstSeenUpdateDate = now.addingTimeInterval(-4 * 86400)
        c.expect(UpdateLogic.shouldEscalate(availableVersion: "1.5.0", state: escalate, now: now), "4 days uninstalled escalates")
        escalate.lastNotifiedVersion = "1.5.0"
        c.expect(!UpdateLogic.shouldEscalate(availableVersion: "1.5.0", state: escalate, now: now), "already-notified version never re-nags")
        escalate.firstSeenUpdateVersion = "1.6.0"
        escalate.firstSeenUpdateDate = now.addingTimeInterval(-4 * 86400)
        c.expect(!UpdateLogic.shouldEscalate(availableVersion: "1.5.0", state: escalate, now: now), "different first-seen version does not escalate")

        // -- Requirement string (must mirror build-app.sh's DR form) --------
        c.expect(UpdateLogic.updateRequirement(fingerprint: "A505B08900C56A28709479297A049525A2A187C6")
                 == "identifier \"com.thomasboch.now\" and certificate root = H\"a505b08900c56a28709479297a049525a2a187c6\"", "DR string format matches build-app.sh")
        c.expect(UpdateLogic.pinnedFingerprints.contains("A505B08900C56A28709479297A049525A2A187C6"), "current signing identity pinned")

        // -- Release notes cleanup ------------------------------------------
        let notes = UpdateLogic.displayNotes("- Fixed X\n- Added Y\n\nFull changelog: https://github.com/BoThomas/now/compare/v1.4.0...v1.5.0\n")
        c.expect(notes == "- Fixed X\n- Added Y", "trailing Full changelog line stripped")
        c.expect(UpdateLogic.displayNotes("  \n- Only item\n\n\n") == "- Only item", "surrounding blanks trimmed")

        // -- Release notes blocks (headings / bullets / paragraphs) ---------
        let blocks = UpdateLogic.noteBlocks("# Added\n- one\n- two\n\nPlain intro paragraph\nspans two lines\n## Fixed\n- three\n- \n\n### Deep heading")
        let expected: [UpdateLogic.NoteBlock] = [
            .heading(level: 1, text: "Added"),
            .bullet(text: "one"),
            .bullet(text: "two"),
            .paragraph(text: "Plain intro paragraph\nspans two lines"),
            .heading(level: 2, text: "Fixed"),
            .bullet(text: "three"),
            .bullet(text: ""),
            .heading(level: 3, text: "Deep heading"),
        ]
        c.expect(blocks == expected, "note blocks parse headings, bullets, paragraphs (got \(blocks))")
        c.expect(UpdateLogic.noteBlocks("* star bullet") == [.bullet(text: "star bullet")], "star bullets supported")
        c.expect(UpdateLogic.noteBlocks("Full changelog: x") == [], "display-notes stripping applies before block parse")
        c.expect(UpdateLogic.noteBlocks("#### Level four") == [.heading(level: 3, text: "Level four")], "heading level capped at 3")
        c.expect(UpdateLogic.noteBlocks("# \n") == [], "empty heading dropped")

        // -- OS floor --------------------------------------------------------
        c.expect(UpdateLogic.meetsMinimumSystemVersion(required: "13.0", osMajor: 13, osMinor: 4, osPatch: 1), "13.0 required, 13.4.1 running passes")
        c.expect(UpdateLogic.meetsMinimumSystemVersion(required: "14.0", osMajor: 13, osMinor: 4, osPatch: 1) == false, "14.0 required, 13.4.1 running refuses")
        c.expect(UpdateLogic.meetsMinimumSystemVersion(required: "13", osMajor: 13, osMinor: 0, osPatch: 0), "single-component requirement passes")
        c.expect(UpdateLogic.meetsMinimumSystemVersion(required: "13.0.1", osMajor: 13, osMinor: 0, osPatch: 1), "three-component requirement passes")
        c.expect(!UpdateLogic.meetsMinimumSystemVersion(required: nil, osMajor: 13, osMinor: 0, osPatch: 0), "missing project LSMinimumSystemVersion rejected")
        c.expect(!UpdateLogic.meetsMinimumSystemVersion(required: "13.0.0.0", osMajor: 14, osMinor: 0, osPatch: 0), "four-component system requirement rejected")
        c.expect(!UpdateLogic.meetsMinimumSystemVersion(required: "013.0", osMajor: 14, osMinor: 0, osPatch: 0), "noncanonical system requirement rejected")
        c.expect(!UpdateLogic.meetsMinimumSystemVersion(required: "13.beta", osMajor: 14, osMinor: 0, osPatch: 0), "nonnumeric system requirement rejected")

        // -- Launch artifact names ------------------------------------------
        let artifactUUID = "12345678-1234-1234-1234-123456789ABC"
        c.expect(UpdateStaging.launchArtifact(named: ".now-update-\(artifactUUID)") == .staging(UUID(uuidString: artifactUUID)!), "canonical staging artifact matched")
        c.expect(UpdateStaging.launchArtifact(named: "now.app.old-\(artifactUUID)") == .backup(UUID(uuidString: artifactUUID)!), "canonical backup artifact matched")
        c.expect(UpdateStaging.launchArtifact(named: ".now-update-\(artifactUUID.lowercased())") == nil, "noncanonical lowercase UUID artifact ignored")
        c.expect(UpdateStaging.launchArtifact(named: ".now-update-\(artifactUUID)-extra") == nil, "UUID artifact suffix ignored")
        c.expect(UpdateStaging.launchArtifact(named: "now.app.old-not-a-uuid") == nil, "non-UUID backup ignored")
        let artifactPath = "/Applications/.now-update-\(artifactUUID)"
        c.expect(!UpdateStaging.shouldRemoveStaging(path: artifactPath, timestamp: now.addingTimeInterval(-3600), activePaths: [], now: now), "fresh staging artifact retained")
        c.expect(UpdateStaging.shouldRemoveStaging(path: artifactPath, timestamp: now.addingTimeInterval(-25 * 3600), activePaths: [], now: now), "stale staging artifact removed")
        c.expect(!UpdateStaging.shouldRemoveStaging(path: artifactPath, timestamp: now.addingTimeInterval(-25 * 3600), activePaths: [artifactPath], now: now), "active stale staging artifact retained")
        c.expect(!UpdateStaging.shouldRemoveStaging(path: artifactPath, timestamp: nil, activePaths: [], now: now), "undated staging artifact retained")

        // -- Install-location refusals ---------------------------------------
        c.expect(UpdateLogic.installLocationProblem("/Applications/now.app") == nil, "normal install location ok")
        c.expect(UpdateLogic.installLocationProblem("/private/var/folders/xy/Ab/App Translocation/123/now.app") != nil, "translocated copy refused")
        c.expect(UpdateLogic.installLocationProblem("/Volumes/now/now.app") != nil, "disk image refused")

        c.notes.append("update decision matrix green")
    }
}
