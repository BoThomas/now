import Foundation
import NowCore

@main struct FeedWorkloadSmoke {
    static func require(_ value: Bool, _ message: String) {
        guard value else { print("FAIL: \(message)"); exit(1) }
        print("PASS: \(message)")
    }
    static func main() {
        setbuf(stdout, nil)
        let now = ISO8601DateFormatter().date(from: "2026-09-08T12:00:00Z")!
        let sub = CalendarSubscription(name: "Workload", url: "https://example.invalid/feed", colorIndex: 0)
        func event(_ uid: String, _ start: String, _ extra: String = "") -> String {
            "BEGIN:VEVENT\nUID:\(uid)\nDTSTART:\(start)\nDURATION:PT1H\nSUMMARY:\(uid)\n\(extra)\nEND:VEVENT\n"
        }
        func feed(_ body: String) -> String { "BEGIN:VCALENDAR\nVERSION:2.0\n" + body + "END:VCALENDAR\n" }
        func build(_ body: String, name: String) -> ICSBuildResult {
            let start = Date()
            let result = ICSBuilder.meetings(fromICS: feed(body), subscription: sub, now: now)
            print("BENCH \(name): \(String(format: "%.3f", Date().timeIntervalSince(start)))s, \(result.events.count) meetings")
            return result
        }
        let standalone = event("standalone", "20260908T130000Z")
        let useful = event("useful", "20260908T130000Z", "RRULE:FREQ=DAILY;COUNT=10")
        let ordinaryHistory = (0..<20_000).map { event("history\($0)", $0 % 2 == 0 ? "20000101T120000Z" : "20400101T120000Z") }.joined()
        let history = build(ordinaryHistory + standalone, name: "20,000 irrelevant records")
        require(history.error == nil && history.events.count == 1, "large irrelevant history preserves useful meeting")
        let medium = (0..<40).map { event("series\($0)", "20100101T130000Z", "RRULE:FREQ=DAILY;COUNT=100000") }.joined()
        let full = build(medium + useful + standalone, name: "40 COUNT series from 2010")
        require(full.error == nil && full.events.count == 571, "raised allowance returns all 571 relevant meetings")
        let old = build(event("old", "19000101T130000Z", "RRULE:FREQ=DAILY;COUNT=100000"), name: "one COUNT series from 1900")
        require(old.error == nil && old.events.count == 14, "old COUNT series completes within raised series allowance")
        let expensive = (0..<15).map { event("expensive\($0)", "19000101T130000Z", "RRULE:FREQ=DAILY;COUNT=100000") }
        let badBody = expensive.joined() + useful + standalone
        let limited = build(badBody, name: "feed budget exhaustion")
        require(limited.events.isEmpty && limited.error?.contains("calendar limit of 500000") == true, "feed budget returns an error without partial events")
        let reordered = build(expensive.reversed().joined() + standalone + useful, name: "reordered feed")
        require(reordered.error == limited.error, "reordering independent series preserves exact diagnostic")
        print("DIAGNOSTIC " + (limited.error ?? "missing"))
        let fetched = AppStore.decodeFeed(Data(feed(badBody).utf8), request: FetchRequest(subscription: sub, requestID: 1), now: now)
        let other = CalendarSubscription(name: "Healthy", url: "https://example.invalid/healthy", colorIndex: 1)
        let healthy = AppStore.decodeFeed(Data(feed(standalone).utf8), request: FetchRequest(subscription: other, requestID: 1), now: now)
        let merged = AppStore.mergeICS(current: full.events, results: [fetched, healthy], live: [sub, other], previousErrors: [:])
        require(Set(merged.events.filter { $0.calendarID == sub.id }.map(\.id)) == Set(full.events.map(\.id)) && merged.errors[sub.id] == limited.error,
                "resource failure preserves the entire cached feed and exposes its detailed error")
        require(merged.events.contains { $0.calendarID == other.id }, "other successful feeds continue updating")
        let recovered = AppStore.mergeICS(current: merged.events, results: [AppStore.decodeFeed(Data(feed(standalone).utf8), request: FetchRequest(subscription: sub, requestID: 2), now: now)], live: [sub, other], previousErrors: merged.errors)
        require(recovered.errors.isEmpty && recovered.events.filter { $0.calendarID == sub.id }.count == 1, "complete recovery replaces cache and clears error")
        print("FEED WORKLOAD SMOKE OK")
    }
}
