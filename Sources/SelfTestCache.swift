import Foundation

extension SelfTest {
    static func calendarCacheTests(_ c: inout Checker) {
        let date = Date(timeIntervalSince1970: 1_788_864_000)
        var sub = CalendarSubscription(name: "Original", url: "https://example.test/private-token", colorIndex: 0)
        let event = MeetingEvent(uid: "cache", title: "Meeting", start: date.addingTimeInterval(60),
                                 end: date.addingTimeInterval(3600), location: "Room", notes: "Notes",
                                 link: URL(string: "https://zoom.us/j/123"), calendarID: sub.id,
                                 calendarName: sub.name, colorIndex: sub.colorIndex)
        let snapshot = CalendarCacheSnapshot(subscription: sub, events: [event], fetchedAt: date, warning: "Degraded feed")
        c.expect(snapshot.isValid && snapshot.events(subscription: sub, now: date).count == 1, "cache: valid occurrence restored")
        c.expect(snapshot.events(subscription: sub, now: event.end).isEmpty, "cache: ended occurrence never restored")
        c.expect(snapshot.events(subscription: sub, now: date.addingTimeInterval(15 * 86400)).isEmpty, "cache: no events beyond saved coverage")
        c.expect(snapshot.events(subscription: sub, now: date.addingTimeInterval(-7 * 3600)).isEmpty, "cache: clock before saved coverage refuses snapshot")
        sub.name = "Renamed"; sub.colorHex = "#abcdef"
        c.expect(snapshot.events(subscription: sub, now: date).first?.calendarName == "Renamed", "cache: live name restored")
        c.expect(snapshot.events(subscription: sub, now: date).first?.colorHex == "#abcdef", "cache: live color restored")
        sub.titleFilters = [TitleFilterRule(pattern: "Meeting")]
        let restored = AppStore.mergeICS(current: snapshot.events(subscription: sub, now: date), results: [], live: [sub], previousErrors: [:])
        c.expect(restored.events.first?.isMuted == true && restored.observedCalendarIDs.isEmpty,
                 "cache: live filters applied without a successful source observation")
        let invalidClock = CalendarCacheSnapshot(subscription: sub, events: [], fetchedAt: Date(timeIntervalSince1970: 1e30), warning: nil)
        c.expect(!invalidClock.isValid, "cache: out-of-range persisted timestamps rejected")
        sub.isEnabled = false
        c.expect(snapshot.events(subscription: sub, now: date).isEmpty, "cache: disabled source rejected")
        sub.isEnabled = true; sub.url += "-edited"
        c.expect(snapshot.events(subscription: sub, now: date).isEmpty, "cache: source URL fingerprint rejects replacement")
        var future = snapshot; future.version += 1
        c.expect(!future.isValid, "cache: unknown schema rejected")
        if let encoded = try? JSONEncoder().encode(snapshot), let decoded = try? JSONDecoder().decode(CalendarCacheSnapshot.self, from: encoded) {
            c.expect(decoded.isValid && decoded.meetings.first?.uid == event.uid && decoded.warning == snapshot.warning, "cache: versioned snapshot round trip")
            c.expect(!String(decoding: encoded, as: UTF8.self).contains("private-token"), "cache: source URL secret not duplicated on disk")
        } else { c.expect(false, "cache: encode/decode succeeds") }
        for code in [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorCancelled] {
            c.expect(!CalendarTransportResult.isOffline(NSError(domain: NSURLErrorDomain, code: code)), "cache: error \(code) does not prove offline")
        }
        c.expect(CalendarTransportResult.isOffline(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)), "cache: offline classification uses URL error code")
        c.expect(!CalendarTransportResult.isOffline(NSError(domain: "other", code: NSURLErrorNotConnectedToInternet)), "cache: offline classification checks error domain")
    }
}
