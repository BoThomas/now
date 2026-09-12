import Foundation
import NowCore

extension CoreTests {
    static func materialization(_ check: inout Check) {
        let sub = cacheSubscription
        let now = instant("2026-09-08T09:00:00Z")
        let feed = calendar([
            event("DTSTART:20260908T100000Z\nRRULE:FREQ=DAILY;COUNT=3\nSUMMARY:Master\nLOCATION:Room\nCONFERENCE:https://zoom.us/j/123"),
            event("RECURRENCE-ID:20260909T100000Z\nDTSTART:20260910T120000Z\nSUMMARY:Moved\nSEQUENCE:1"),
            event("RECURRENCE-ID:20260910T100000Z\nDTSTART:20260910T120000Z\nSUMMARY:\nLOCATION:\nCONFERENCE:https://meet.google.com/abc-defg-hij")
        ].joined(separator: "\n"))
        var detections = 0
        let built = ICSBuilder.meetings(fromICS: feed, subscription: sub, now: now, colorHex: sub.colorHex, detectLink: { parsed in
            detections += 1
            return LinkExtractor.link(from: parsed, urlsInText: { _ in [] })
        })
        check.expect(built.error == nil && built.events.count == 3, "full feed materialization preserves master and moved siblings")
        let moved = built.events.filter { $0.start == instant("2026-09-10T12:00:00Z") }
        check.expect(moved.count == 2 && Set(moved.map(\.id)).count == 2 && Set(moved.compactMap(\.notificationIdentity)).count == 2, "coincident overrides retain distinct agenda/receipt identities")
        check.expect(moved.first(where: { $0.title == "" })?.location == "" && moved.first(where: { $0.title == "Moved" })?.location == "Room", "explicit empty versus omitted override inheritance")
        check.expect(Set(built.events.compactMap { $0.link?.host }) == ["zoom.us", "meet.google.com"] && detections == 3, "one lazy link detection per materialized revision")
        let snapshot = CalendarCacheSnapshot(subscription: sub, events: built.events, fetchedAt: now, warning: nil)
        check.expect(snapshot.events(subscription: sub, now: now).map(\.id) == built.events.map(\.id), "feed-to-cache preserves complete occurrence output")

        func build(_ text: String) -> ICSBuildResult {
            ICSBuilder.meetings(fromICS: text, subscription: sub, now: now, colorHex: sub.colorHex,
                                detectLink: { LinkExtractor.link(from: $0, urlsInText: { _ in [] }) })
        }
        let malformed = build(feed + "BEGIN:VCALENDAR\n")
        check.expect(malformed.error != nil && malformed.events.isEmpty, "complete prefix plus truncation never becomes accepted partial materialization")
        check.expect(build(calendar("")).error == nil && build(calendar("")).events.isEmpty, "valid empty feed stays successful")
        let unsupported = build(calendar(event("DTSTART:20260908T100000Z\nRRULE:FREQ=HOURLY")))
        check.expect(unsupported.events.count == 1 && !unsupported.warnings.isEmpty, "unsupported recurrence warns and falls back")
        let excessive = build(calendar(event("DTSTART:16000101T100000Z\nRRULE:FREQ=DAILY;COUNT=200000")))
        check.expect(excessive.error != nil && excessive.events.isEmpty, "incomplete recurrence expansion rejects whole materialization")
        let excluded = build(calendar(event("DTSTART:20260908T100000Z\nRRULE:FREQ=DAILY;COUNT=3\nEXDATE:20260909T100000Z\nRDATE:20260911T100000Z")))
        check.expect(excluded.events.map(\.start) == ["2026-09-08T10:00:00Z", "2026-09-10T10:00:00Z", "2026-09-11T10:00:00Z"].map(instant), "RDATE/EXDATE materialization is exact")
        let clean = build(calendar(event("DTSTART:20260908T100000Z\nRRULE:FREQ=DAILY;COUNT=14")))
        check.expect(clean.events.count == 14 && clean.events.allSatisfy { $0.colorHex == sub.colorHex }, "materialization uses supplied presentation color")
    }
}
