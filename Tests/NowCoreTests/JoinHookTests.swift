import Foundation
import NowCore

extension CoreTests {
    static func joinHook(_ check: inout Check) {
        let id = UUID()
        let start = instant("2027-03-04T10:00:00Z")
        let event = MeetingEvent(uid: "uid", title: "Team Sync; rm -rf $(echo hi)", start: start,
                                 end: start.addingTimeInterval(1800), location: nil, notes: nil,
                                 link: URL(string: "https://zoom.us/j/123?pwd=abc"), calendarID: id,
                                 calendarName: "Work", colorIndex: 0, colorHex: "#123456",
                                 notificationIdentity: nil)
        // Untrusted content travels as values only: shell syntax in a title
        // stays an inert environment value and never enters a command string.
        let environment = JoinHook.environment(for: event)
        check.expect(environment["NOW_TITLE"] == "Team Sync; rm -rf $(echo hi)", "title passes through verbatim as an environment value")
        check.expect(environment["NOW_CALENDAR"] == "Work", "calendar name in environment")
        check.expect(environment["NOW_URL"] == "https://zoom.us/j/123?pwd=abc", "join link in environment")
        check.expect(environment["NOW_START"] == "2027-03-04T10:00:00Z" && environment["NOW_END"] == "2027-03-04T10:30:00Z", "start/end are unambiguous ISO8601")
        let linkless = MeetingEvent(uid: "uid", title: "Offline", start: start, end: start.addingTimeInterval(60),
                                    location: nil, notes: nil, link: nil, calendarID: id, calendarName: "Work",
                                    colorIndex: 0, colorHex: "#123456", notificationIdentity: nil)
        check.expect(JoinHook.environment(for: linkless)["NOW_URL"] == "", "missing link is an empty value, not a placeholder")

        check.expect(JoinHook.normalizedCommand("  watson start meetings  ") == "watson start meetings", "command trims")
        check.expect(JoinHook.normalizedCommand(" \n ") == nil, "blank command never runs")
        check.expect(JoinHook.normalizedCommand(String(repeating: "x", count: JoinHook.maxCommandLength + 1)) == nil, "oversized command never runs")

        check.expect(JoinHook.excerpt(from: nil) == nil && JoinHook.excerpt(from: "  \n ") == nil, "no stderr yields no excerpt")
        let long = String(repeating: "x", count: 500)
        check.expect(JoinHook.excerpt(from: long)?.count == 200, "excerpt is capped short")
        check.expect(JoinHook.excerpt(from: " boom\n") == "boom", "excerpt trims surrounding whitespace")

        var runs = (0..<(JoinHook.maxRuns + 5)).reversed().map {
            JoinHookRun(date: Date(timeIntervalSince1970: Double($0)), title: "M\($0)", isTest: false, outcome: .success)
        }
        runs = JoinHook.capped(runs)
        check.expect(runs.count == JoinHook.maxRuns && runs.first?.title == "M\(JoinHook.maxRuns + 4)" && runs.last?.title == "M5",
                     "history keeps the newest entries")

        // Hook execution survives Snooze/restart independently of reminder
        // suppression; only a reschedule re-arms the same occurrence.
        var ledger = ReminderLedger()
        check.expect(!ledger.hasRunJoinHook(event), "unjoined occurrence has not run the hook")
        ledger.join(event)
        check.expect(!ledger.hasRunJoinHook(event), "joining with the hook disabled does not consume its execution")
        ledger.join(event, recordingJoinHook: true)
        check.expect(ledger.hasRunJoinHook(event), "hook request marks the occurrence")
        ledger.schedule(event, until: start.addingTimeInterval(60), leads: [300])
        check.expect(ledger.hasRunJoinHook(event)
                         && !ledger.suppressAfterJoin(event, detectionEnabled: false, activity: .inactive),
                     "Snooze clears reminder suppression but preserves hook execution")
        ledger.join(event)
        check.expect(ledger.hasRunJoinHook(event), "joining again preserves the hook marker")
        let restored = (try? JSONEncoder().encode(ledger)).flatMap { try? JSONDecoder().decode(ReminderLedger.self, from: $0) }
        check.expect(restored?.hasRunJoinHook(event) == true, "hook execution survives ledger round trip")
        if let data = try? JSONEncoder().encode(ledger),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var entries = json["entries"] as? [String: [String: Any]] {
            let key = ReminderIdentity.eventKey(event)
            entries[key]?.removeValue(forKey: "joinHookRan")
            json["entries"] = entries
            let legacy = (try? JSONSerialization.data(withJSONObject: json)).flatMap {
                try? JSONDecoder().decode(ReminderLedger.self, from: $0)
            }
            check.expect(legacy != nil && legacy?.hasRunJoinHook(event) == false, "legacy ledger without hook marker decodes")
        } else { check.expect(false, "legacy hook ledger fixture encodes") }
        let other = MeetingEvent(uid: "uid-2", title: "Other", start: start.addingTimeInterval(3600),
                                 end: start.addingTimeInterval(5400), location: nil, notes: nil, link: nil,
                                 calendarID: id, calendarName: "Work", colorIndex: 0, colorHex: "#123456",
                                 notificationIdentity: nil)
        check.expect(!ledger.hasRunJoinHook(other), "other occurrences stay independent")
        _ = ledger.reconcile(events: [event], enabled: [id], observed: [id], now: start.addingTimeInterval(-60),
                             previousEvents: [event], leads: [300])
        check.expect(ledger.hasRunJoinHook(event), "unchanged schedule keeps the hook marker")
        let moved = MeetingEvent(uid: "uid", title: event.title, start: start.addingTimeInterval(900),
                                 end: event.end.addingTimeInterval(900), location: nil, notes: nil,
                                 link: event.link, calendarID: id, calendarName: "Work", colorIndex: 0,
                                 colorHex: "#123456", notificationIdentity: nil)
        _ = ledger.reconcile(events: [moved], enabled: [id], observed: [id], now: start, previousEvents: [event], leads: [300])
        check.expect(!ledger.hasRunJoinHook(moved), "rescheduled occurrence may run the hook again")

        check.expect(!AppSettings().joinHookEnabled && AppSettings().joinHookCommand.isEmpty, "join hook defaults to off and empty")
        check.expect(JoinHook.shouldRun(enabled: true, command: "echo hi", hasRun: false)
                         && !JoinHook.shouldRun(enabled: true, command: "echo hi", hasRun: true),
                     "hook decision requires enabled, usable command and an unused occurrence")
        check.expect(!JoinHook.shouldRun(enabled: true, command: "   ", hasRun: false), "blank command blocks the hook")
        check.expect(!JoinHook.shouldRun(enabled: false, command: "echo hi", hasRun: false), "disabled hook never runs")
    }
}
