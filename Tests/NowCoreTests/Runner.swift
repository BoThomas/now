import Foundation
import NowCore

/// A real library consumer: no app sources, platform detector, preferences or network.
@main enum CoreTests {
    struct Check {
        var count = 0
        var failures: [String] = []
        mutating func expect(_ value: Bool, _ label: String) {
            count += 1
            if !value { failures.append(label) }
        }
    }

    static func main() async {
        #if os(macOS) || os(Linux)
        if CommandLine.arguments.count == 3, CommandLine.arguments[1].hasPrefix("--cache-") {
            do { try await cacheChild(mode: CommandLine.arguments[1], directory: URL(fileURLWithPath: CommandLine.arguments[2])) }
            catch { print("CACHE CHILD FAILED: \(error)"); exit(1) }
            return
        }
        #endif
        var check = Check()
        envelopes(&check)
        datesAndOverrides(&check)
        recurrence(&check)
        links(&check)
        do {
            try modelDecoding(&check)
            try modelRecovery(&check)
            try modelEncoding(&check)
            titleFilters(&check)
            meetingIdentity(&check)
            try cachePolicy(&check)
            #if os(macOS) || os(Linux)
            try await cacheStorage(&check)
            #endif
            try ledgerLifecycle(&check)
            reminderDecisions(&check)
            observationOwnership(&check)
            snoozeDecisions(&check)
            materialization(&check)
            calendarMerge(&check)
        } catch {
            check.expect(false, "model fixture failed to decode/encode: \(error)")
        }
        if !check.failures.isEmpty {
            for failure in check.failures { print("FAIL: \(failure)") }
            exit(1)
        }
        print("CORE TESTS OK — \(check.count) checks; parsing/materialization, models, cache/restart, hashing, reminder/ledger/snooze policy")
    }

    static func calendar(_ body: String) -> String {
        "BEGIN:VCALENDAR\nVERSION:2.0\n" + body + "\nEND:VCALENDAR\n"
    }

    static func event(_ properties: String) -> String {
        "BEGIN:VEVENT\nUID:fixture\n" + properties + "\nEND:VEVENT"
    }

    static func instant(_ value: String) -> Date {
        // Fixed UTC expected instants, independent of the parser under test.
        guard let date = ISO8601DateFormatter().date(from: value) else {
            fatalError("Invalid test instant: \(value)")
        }
        return date
    }

    static func envelopes(_ check: inout Check) {
        let body = event("DTSTART:20260908T100000Z\nSUMMARY:Team\\, sync\nDESCRIPTION:folded\n text")
        let feed = calendar(body)
        for source in [feed, feed.replacingOccurrences(of: "\n", with: "\r\n"),
                       feed.replacingOccurrences(of: "\n", with: "\r"), "\u{FEFF}" + feed] {
            let result = ICSParser.parse(source)
            check.expect(result.error == nil && result.events.count == 1, "complete envelope and line endings")
            check.expect(result.events.first?.title == "Team, sync" && result.events.first?.description == "foldedtext",
                         "unescape and unfolding")
        }
        for bad in [feed + "BEGIN:VCALENDAR\n", calendar(body + "\nBEGIN:VEVENT"),
                    calendar("BEGIN:VEVENT\nEND:VTODO"), "SUMMARY:outside\n" + feed,
                    calendar("BEGIN:VCALENDAR\nEND:VCALENDAR")] {
            let result = ICSParser.parse(bad)
            check.expect(result.error != nil && result.events.isEmpty, "reject entire malformed/truncated feed")
        }
        let empty = ICSParser.parse(calendar(""))
        check.expect(empty.error == nil && empty.events.isEmpty, "complete empty calendar succeeds")
        let exact = String(repeating: "x", count: ICSParser.maxLineLength)
        check.expect((try? ICSParser.unfolded(exact)) == [exact], "exact unfolded line limit")
        check.expect((try? ICSParser.unfolded(exact + "\n x")) == nil, "folding cannot bypass line limit")
        check.expect((try? ICSParser.unfolded(String(repeating: "\n", count: ICSParser.maxLines))) != nil, "exact physical line limit")
        check.expect((try? ICSParser.unfolded(String(repeating: "\n", count: ICSParser.maxLines + 1))) == nil, "physical line overflow")
        check.expect(ICSParser.parseDuration("P1DT2H") == 93_600, "day and time duration")
        for invalid in ["P1M", "P1DT", "PT1M2H", "P1W1D", "PT999999999999999999999H"] {
            check.expect(ICSParser.parseDuration(invalid) == nil, "reject malformed/oversized duration \(invalid)")
        }
    }

    static func datesAndOverrides(_ check: inout Check) {
        let start = "DTSTART;TZID=W. Europe Standard Time:20260908T100000"
        let result = ICSParser.parse(calendar(event(start + "\nDURATION:PT30M")))
        check.expect(result.events.first?.dtStart == instant("2026-09-08T08:00:00Z"), "Windows TZID mapping")
        check.expect(result.events.first?.durationSeconds == 1800, "duration survives module boundary")
        let unknown = ICSParser.parse(calendar(event("DTSTART;TZID=Imaginary/Nowhere:20260908T100000")))
        check.expect(unknown.error == nil && unknown.events.isEmpty && !unknown.warnings.isEmpty, "unknown zone skips with warning")
        let raw = ICSProperty(name: "RECURRENCE-ID", params: [:], value: "20260909T100000")
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let newYork = TimeZone(identifier: "America/New_York")!
        let cache = ICSDateFormatters()
        check.expect(ICSParser.parseDate(raw, fallbackTimeZone: berlin, dateFormatters: cache).date == instant("2026-09-09T08:00:00Z"), "floating identity uses supplied master zone")
        check.expect(ICSParser.parseDate(raw, fallbackTimeZone: newYork, dateFormatters: cache).date == instant("2026-09-09T14:00:00Z"), "formatter cache separates zones")

        let overrides = ICSParser.parse(calendar([
            event("DTSTART:20260908T100000Z\nRRULE:FREQ=DAILY;COUNT=3\nSUMMARY:Master"),
            event("RECURRENCE-ID:20260909T100000Z\nDTSTART:20260910T120000Z\nSUMMARY:\nSEQUENCE:2"),
            event("RECURRENCE-ID:20260910T100000Z\nDTSTART:20260910T120000Z\nLOCATION:")
        ].joined(separator: "\n")))
        check.expect(overrides.events.count == 3, "retain master and coincident moved siblings")
        let detached = overrides.events.filter { $0.recurrenceIDProperty != nil }
        check.expect(Set(detached.compactMap(\.recurrenceID)).count == 2 && Set(detached.compactMap(\.dtStart)).count == 1,
                     "raw original recurrence anchors remain distinct from actual starts")
        check.expect(detached.first?.hasExplicitTitle == true && detached.first?.title == "" && detached.first?.sequence == 2,
                     "explicit empty title and revision retained")
        check.expect(detached.last?.location == "" && detached.last?.description == nil, "empty and omitted fields remain distinct")
    }

    static func recurrence(_ check: inout Check) {
        let cases: [(String, String, [String])] = [
            ("20260328T023000", "FREQ=DAILY;COUNT=3", ["2026-03-28T01:30:00Z", "2026-03-30T00:30:00Z", "2026-03-31T00:30:00Z"]),
            ("20261024T023000", "FREQ=DAILY;COUNT=3", ["2026-10-24T00:30:00Z", "2026-10-25T00:30:00Z", "2026-10-26T01:30:00Z"]),
            ("20260322T023000", "FREQ=WEEKLY;COUNT=3", ["2026-03-22T01:30:00Z", "2026-04-05T00:30:00Z", "2026-04-12T00:30:00Z"]),
            ("20260228T023000", "FREQ=MONTHLY;BYMONTHDAY=-1;COUNT=3", ["2026-02-28T01:30:00Z", "2026-03-31T00:30:00Z", "2026-04-30T00:30:00Z"]),
            ("20240229T100000", "FREQ=YEARLY;COUNT=2", ["2024-02-29T09:00:00Z", "2028-02-29T09:00:00Z"])
        ]
        for (start, rule, expected) in cases {
            let parsed = ICSParser.parse(calendar(event("DTSTART;TZID=Europe/Berlin:\(start)\nRRULE:\(rule)")))
            guard let item = parsed.events.first else { check.expect(false, "recurrence parses"); continue }
            let dates = expected.map(instant)
            var budget = RRULEExpander.maxIterationsPerEvent
            let result = RRULEExpander.expand(item, windowStart: dates.first!, windowEnd: dates.last!, budget: &budget)
            check.expect(result.completed && result.dates == dates, "exact recurrence instants: \(start) \(rule)")
        }
        for rule in ["FREQ=HOURLY", "FREQ=DAILY;COUNT=2;UNTIL=20260910T100000Z", "FREQ=DAILY;BYDAY=1MO", "FREQ=DAILY;UNKNOWN=1"] {
            check.expect(RRULE.parse(rule, eventTz: TimeZone(secondsFromGMT: 0)) == nil, "unsupported RRULE rejected")
        }
        guard var item = ICSParser.parse(calendar(event("DTSTART:20260908T100000Z\nRRULE:FREQ=DAILY;COUNT=3"))).events.first else {
            check.expect(false, "budget fixture parses"); return
        }
        let start = instant("2026-09-08T10:00:00Z"), end = instant("2026-09-10T10:00:00Z")
        var exact = 3
        let complete = RRULEExpander.expand(item, windowStart: start, windowEnd: end, budget: &exact)
        check.expect(complete.completed && complete.dates.count == 3 && exact == 0, "exact recurrence budget succeeds")
        var short = 2
        let partial = RRULEExpander.expand(item, windowStart: start, windowEnd: end, budget: &short)
        check.expect(!partial.completed && short == 0, "insufficient budget explicitly incomplete")
        item.exdates = [start]
        check.expect(RRULEExpander.occurrences(of: item, windowStart: start, windowEnd: end) == [start.addingTimeInterval(86400), end],
                     "EXDATE removes anchor without extending COUNT")
    }

    static func links(_ check: inout Check) {
        guard var item = ICSParser.parse(calendar(event("DTSTART:20260908T100000Z"))).events.first else {
            check.expect(false, "link fixture parses"); return
        }
        // Synthetic discovery tests selection policy; it does not implement or claim
        // parity with NSDataDetector on Linux.
        let zoom = URL(string: "https://zoom.us/j/123?pwd=abc")!
        let meet = URL(string: "https://meet.google.com/abc-defg-hij")!
        let docs = URL(string: "https://example.invalid/document")!
        item.location = "room"
        item.description = "notes"
        check.expect(LinkExtractor.link(from: item, urlsInText: { $0 == "room" ? [docs, zoom] : [meet] }) == zoom,
                     "recognized location link wins over description")
        item.conference = docs.absoluteString
        check.expect(LinkExtractor.link(from: item, urlsInText: { _ in [zoom] }) == docs, "explicit conference remains authoritative")
        item.conference = nil
        check.expect(LinkExtractor.link(from: item, urlsInText: { _ in [docs] }) == nil, "no arbitrary web-link fallback")
        check.expect(LinkExtractor.joinURL("zoommtg://zoom.us/join?confno=123&pwd=abc") == zoom, "native Zoom conversion preserves password")
        check.expect(LinkExtractor.joinURL("javascript:alert(1)") == nil, "non-web scheme rejected")
        check.expect(LinkExtractor.isMeetingLink(URL(string: "https://example.webex.com/site/j.php?MTID=opaque")!), "Webex scheduled shape")
        check.expect(!LinkExtractor.isMeetingLink(URL(string: "https://webex.com.evil.invalid/site/j.php?MTID=opaque")!), "Webex lookalike rejected")
        check.expect(LinkExtractor.decodeHTMLEntities("&amp;lt;") == "&lt;", "HTML entities decoded only once")
    }
}
